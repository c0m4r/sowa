/*
 * sowa-init - System V style init(8) for Sowa Linux.
 *
 * It reads /etc/inittab, runs the entries a runlevel asks for, keeps the
 * respawning ones alive, reaps whatever the system orphans onto it, listens on
 * /run/initctl for telinit and shutdown, and takes the machine down itself
 * when it reaches runlevel 0 or 6.
 *
 * Two things are worth knowing before reading the rest.
 *
 * The event loop is a signalfd and the control FIFO in one poll(2), not the
 * classic mixture of signal handlers and interruptible sleeps. Everything init
 * reacts to - a child exiting, a runlevel request, the deadline on a SIGTERM
 * it sent - arrives at the same place, so there is no window where a SIGCHLD
 * can be lost between checking a flag and sleeping on it.
 *
 * Entries are started by walking the inittab in order and stopping at each one
 * the action says to wait for. That walk is the "pass", and it is resumable:
 * the cursor and the entry being waited on are state, so waiting for
 * /etc/rc.d/rc to finish does not block signal handling or reaping the way a
 * blocking waitpid() would.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/signalfd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "initreq.h"

#ifndef VERSION
#define VERSION "0.1"
#endif

#define INITTAB "/etc/inittab"
#define CONSOLE "/dev/console"
#define SHELL "/bin/sh"
#define INIT_PATH "/bin:/sbin:/usr/bin:/usr/sbin"

/* A respawn entry that starts more often than this is misconfigured or broken,
 * and retrying it forever would bury the console under its failure. The
 * numbers are System V's. */
#define RESPAWN_STARTS 10
#define RESPAWN_WINDOW 120
#define RESPAWN_PAUSE 300

/* How long a process gets between the SIGTERM that asks it to leave a runlevel
 * and the SIGKILL that makes it. shutdown(8) can override the shutdown-time
 * value through the request's sleeptime field. */
#define KILL_GRACE 5

enum action {
	A_UNKNOWN = 0,
	A_RESPAWN,
	A_WAIT,
	A_ONCE,
	A_BOOT,
	A_BOOTWAIT,
	A_SYSINIT,
	A_OFF,
	A_ONDEMAND,
	A_INITDEFAULT,
	A_CTRLALTDEL,
	A_POWERFAIL,
	A_POWERWAIT,
	A_POWEROKWAIT,
	A_KBREQUEST
};

static const struct {
	const char *name;
	enum action action;
} action_names[] = {
	{ "respawn", A_RESPAWN },
	{ "wait", A_WAIT },
	{ "once", A_ONCE },
	{ "boot", A_BOOT },
	{ "bootwait", A_BOOTWAIT },
	{ "sysinit", A_SYSINIT },
	{ "off", A_OFF },
	{ "ondemand", A_ONDEMAND },
	{ "initdefault", A_INITDEFAULT },
	{ "ctrlaltdel", A_CTRLALTDEL },
	{ "powerfail", A_POWERFAIL },
	{ "powerwait", A_POWERWAIT },
	{ "powerokwait", A_POWEROKWAIT },
	{ "kbrequest", A_KBREQUEST },
	{ NULL, A_UNKNOWN }
};

struct entry {
	struct entry *next;
	char id[16];
	char runlevels[16];		/* empty means every runlevel */
	enum action action;
	int own_tty;			/* "@": the process handles its own    */
	char *process;
	pid_t pid;
	int started_here;		/* started since the runlevel was entered */
	int terminating;		/* SIGTERM sent, SIGKILL pending        */
	long kill_at;			/* monotonic deadline for that SIGKILL  */
	long blocked_until;		/* monotonic, set by respawn throttling */
	long starts[RESPAWN_STARTS];	/* ring of recent start times           */
	int start_count;
};

enum phase {
	PH_SYSINIT,			/* the sysinit entries, one at a time */
	PH_BOOT,			/* boot and bootwait                  */
	PH_RUNLEVEL,			/* wait, once and respawn             */
	PH_IDLE				/* nothing left to start              */
};

static struct entry *entries;
static struct entry *cursor;		/* next entry the pass will consider */
static struct entry *blocking;		/* entry the pass is waiting for     */
static enum phase phase = PH_SYSINIT;

static char runlevel = 'N';
static char prevlevel = 'N';
static char boot_runlevel;		/* what the boot pass ends up entering */
static int reload_pending;
static int shutdown_grace = 3;
static int halt_instead_of_poweroff;

static int console_fd = -1;
static int fifo_fd = -1;

static long monotonic(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
		return 0;
	return (long)ts.tv_sec;
}

/*
 * Everything init has to say goes to the console it was given, reopened if it
 * was lost. Nothing here writes to the kernel log: the console is where a boot
 * is watched, and dmesg keeps the kernel's own account of it.
 */
static void open_console(void)
{
	int fd;

	if (console_fd >= 0)
		return;
	fd = open(CONSOLE, O_WRONLY | O_NOCTTY | O_CLOEXEC);
	if (fd < 0)
		fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
	console_fd = fd;
}

__attribute__((format(printf, 1, 2)))
static void notice(const char *fmt, ...)
{
	char message[512];
	va_list args;
	int length;

	open_console();
	if (console_fd < 0)
		return;

	va_start(args, fmt);
	length = vsnprintf(message, sizeof(message) - 8, fmt, args);
	va_end(args);
	if (length < 0)
		return;
	if ((size_t)length > sizeof(message) - 8)
		length = (int)sizeof(message) - 8;
	message[length++] = '\r';
	message[length++] = '\n';
	if (write(console_fd, message, (size_t)length) < 0) {
		close(console_fd);
		console_fd = -1;
	}
}

static void *xmalloc(size_t size)
{
	void *pointer = malloc(size);

	/* PID 1 cannot fail an allocation and carry on, and it cannot exit
	 * either: the kernel panics when it does. Say so and stop. */
	if (!pointer) {
		notice("init: out of memory");
		for (;;)
			pause();
	}
	return pointer;
}

static char *xstrdup(const char *text)
{
	size_t size = strlen(text) + 1;

	return memcpy(xmalloc(size), text, size);
}

static char *trim(char *text)
{
	char *end;

	while (*text == ' ' || *text == '\t')
		text++;
	end = text + strlen(text);
	while (end > text && (end[-1] == ' ' || end[-1] == '\t' ||
			      end[-1] == '\r' || end[-1] == '\n'))
		*--end = '\0';
	return text;
}

static enum action lookup_action(const char *name)
{
	int index;

	for (index = 0; action_names[index].name; index++)
		if (!strcasecmp(name, action_names[index].name))
			return action_names[index].action;
	return A_UNKNOWN;
}

static int in_runlevel(const struct entry *entry, char level)
{
	const char *levels = entry->runlevels;

	/* An empty runlevel field means "every runlevel", which is what makes
	 * sysinit, ctrlaltdel and powerfail entries independent of one. */
	if (!*levels)
		return 1;
	if (level == 'S')
		return strchr(levels, 'S') || strchr(levels, 's');
	return strchr(levels, level) != NULL;
}

/*
 * id:runlevels:action:process, with the process free to contain colons of its
 * own - so only the first three fields are split off.
 */
static struct entry *parse_line(char *line, int number)
{
	struct entry *entry;
	char *fields[3];
	char *rest = line;
	char *value;
	enum action action;
	int own_tty;
	int index;

	for (index = 0; index < 3; index++) {
		char *colon = strchr(rest, ':');

		if (!colon) {
			notice("init: %s:%d: not enough fields", INITTAB, number);
			return NULL;
		}
		*colon = '\0';
		fields[index] = trim(rest);
		rest = colon + 1;
	}

	action = lookup_action(fields[2]);
	if (action == A_UNKNOWN) {
		notice("init: %s:%d: unknown action \"%s\"", INITTAB, number,
		       fields[2]);
		return NULL;
	}

	/* initdefault names a runlevel rather than a command, and an "off"
	 * entry is one that has been commented out without deleting it. Every
	 * other action has something to run. */
	value = trim(rest);
	/* A leading "@" is the entry saying it wants no terminal from init.
	 * See child_console(). */
	own_tty = *value == '@';
	if (own_tty)
		value = trim(value + 1);
	if (!*value && action != A_OFF && action != A_INITDEFAULT) {
		notice("init: %s:%d: no command", INITTAB, number);
		return NULL;
	}

	entry = xmalloc(sizeof(*entry));
	memset(entry, 0, sizeof(*entry));
	snprintf(entry->id, sizeof(entry->id), "%s", fields[0]);
	snprintf(entry->runlevels, sizeof(entry->runlevels), "%s", fields[1]);
	entry->action = action;
	entry->own_tty = own_tty;
	entry->process = xstrdup(value);
	return entry;
}

/*
 * Reads the inittab into a fresh list. Nothing is started here; parsing and
 * running are separate so that a reload can compare the two lists first.
 */
static struct entry *read_inittab(void)
{
	FILE *file;
	struct entry *list = NULL;
	struct entry *last = NULL;
	char line[1024];
	int number = 0;

	file = fopen(INITTAB, "re");
	if (!file) {
		notice("init: cannot read %s: %s", INITTAB, strerror(errno));
		return NULL;
	}

	while (fgets(line, sizeof(line), file)) {
		struct entry *entry;
		char *text = trim(line);

		number++;
		if (!*text || *text == '#')
			continue;
		entry = parse_line(text, number);
		if (!entry)
			continue;
		if (last)
			last->next = entry;
		else
			list = entry;
		last = entry;
	}
	fclose(file);
	return list;
}

/*
 * The inittab Sowa falls back on when /etc/inittab is missing or unusable: a
 * root shell on the console, respawned. It is not a rescue system, it is the
 * one thing that makes the machine repairable from where you are standing.
 */
static struct entry *emergency_inittab(const char *why)
{
	struct entry *entry = xmalloc(sizeof(*entry));

	notice("init: %s; starting a shell on %s", why, CONSOLE);
	memset(entry, 0, sizeof(*entry));
	snprintf(entry->id, sizeof(entry->id), "~~");
	entry->action = A_RESPAWN;
	entry->process = xstrdup(SHELL " -l");
	return entry;
}

static char initdefault_runlevel(void)
{
	struct entry *entry;

	for (entry = entries; entry; entry = entry->next) {
		if (entry->action != A_INITDEFAULT)
			continue;
		if (entry->runlevels[0])
			return toupper((unsigned char)entry->runlevels[0]);
	}
	return 0;
}

/*
 * Whether the command needs a shell to mean what it says. System V's test,
 * and the reason an inittab line can carry a redirection or a quoted argument
 * without init having to grow a parser for either.
 */
static int needs_shell(const char *command)
{
	return strpbrk(command, "~`!$^&*()=|\\{}[];\"'<>?") != NULL;
}

/*
 * The terminal a child starts life with.
 *
 * Almost everything init runs wants the console: an rc script's output belongs
 * there, and the single-user shell needs it as a controlling terminal for job
 * control. A getty is the exception. It is told on the command line which
 * device it serves, opens that device itself, and makes it the controlling
 * terminal of the session it hands to login - which it cannot do from a session
 * that already holds /dev/console. So an entry marked "@" is left alone: no
 * console, no controlling terminal, /dev/null on its three standard
 * descriptors, and the rest is the program's own business.
 */
static void child_console(int own_tty, int want_ctty)
{
	int fd;

	setsid();
	fd = open(own_tty ? "/dev/null" : CONSOLE, O_RDWR | O_NOCTTY);
	if (fd < 0)
		fd = open("/dev/null", O_RDWR);
	if (fd < 0)
		return;
	dup2(fd, STDIN_FILENO);
	dup2(fd, STDOUT_FILENO);
	dup2(fd, STDERR_FILENO);
	if (fd > STDERR_FILENO)
		close(fd);

	/*
	 * Only the interactive entries claim the console as their controlling
	 * terminal, and they claim it away from whoever held it. A login shell
	 * needs one for job control and for Ctrl-C to reach the right process
	 * group; rc scripts do not, and letting them take it would leave the
	 * shell on the console without one for the rest of the runlevel.
	 */
	if (want_ctty)
		ioctl(STDIN_FILENO, TIOCSCTTY, 1);
}

static void child_environment(void)
{
	char level[2] = { runlevel, '\0' };
	char previous[2] = { prevlevel, '\0' };

	setenv("PATH", INIT_PATH, 1);
	setenv("HOME", "/", 1);
	setenv("CONSOLE", CONSOLE, 1);
	setenv("INIT_VERSION", "sowa-init " VERSION, 1);
	setenv("RUNLEVEL", level, 1);
	setenv("PREVLEVEL", previous, 1);
	if (!getenv("TERM"))
		setenv("TERM", "linux", 1);
}

static void exec_command(const char *command)
{
	char *argv[64];
	char *copy;
	char *save = NULL;
	char *word;
	int count = 0;

	if (needs_shell(command)) {
		execl(SHELL, "sh", "-c", command, (char *)NULL);
		notice("init: cannot execute %s: %s", SHELL, strerror(errno));
		_exit(127);
	}

	copy = xstrdup(command);
	for (word = strtok_r(copy, " \t", &save); word && count < 63;
	     word = strtok_r(NULL, " \t", &save))
		argv[count++] = word;
	argv[count] = NULL;
	if (!count)
		_exit(127);

	execvp(argv[0], argv);
	notice("init: cannot execute %s: %s", argv[0], strerror(errno));
	_exit(127);
}

/*
 * Records a start and reports whether the entry has been restarting too fast.
 * The window is a ring of the last RESPAWN_STARTS start times: if the oldest
 * of them is recent, the entry is failing rather than running.
 */
static int respawning_too_fast(struct entry *entry)
{
	long now = monotonic();
	long oldest;
	int index;

	index = entry->start_count % RESPAWN_STARTS;
	oldest = entry->starts[index];
	entry->starts[index] = now;
	entry->start_count++;

	if (entry->start_count <= RESPAWN_STARTS)
		return 0;
	return now - oldest < RESPAWN_WINDOW;
}

static int spawn(struct entry *entry)
{
	int want_ctty = !entry->own_tty && (entry->action == A_RESPAWN ||
					    entry->action == A_ONDEMAND);
	sigset_t empty;
	pid_t pid;

	if (entry->action == A_RESPAWN && respawning_too_fast(entry)) {
		entry->blocked_until = monotonic() + RESPAWN_PAUSE;
		notice("init: id \"%s\" respawning too fast: disabled for %d minutes",
		       entry->id, RESPAWN_PAUSE / 60);
		return 0;
	}

	pid = fork();
	if (pid < 0) {
		notice("init: cannot fork for id \"%s\": %s", entry->id,
		       strerror(errno));
		return 0;
	}
	if (pid == 0) {
		sigemptyset(&empty);
		sigprocmask(SIG_SETMASK, &empty, NULL);
		signal(SIGPIPE, SIG_DFL);
		child_console(entry->own_tty, want_ctty);
		child_environment();
		exec_command(entry->process);
		_exit(127);
	}

	entry->pid = pid;
	entry->started_here = 1;
	entry->terminating = 0;
	return 1;
}

static int phase_matches(const struct entry *entry)
{
	switch (phase) {
	case PH_SYSINIT:
		return entry->action == A_SYSINIT;
	case PH_BOOT:
		return entry->action == A_BOOT || entry->action == A_BOOTWAIT;
	case PH_RUNLEVEL:
		if (entry->action != A_RESPAWN && entry->action != A_WAIT &&
		    entry->action != A_ONCE)
			return 0;
		return in_runlevel(entry, runlevel);
	case PH_IDLE:
		return 0;
	}
	return 0;
}

static int phase_blocks(const struct entry *entry)
{
	return entry->action == A_SYSINIT || entry->action == A_BOOTWAIT ||
	       entry->action == A_WAIT;
}

static void write_runlevel_state(void)
{
	char text[8];
	int fd;

	snprintf(text, sizeof(text), "%c %c\n", prevlevel, runlevel);
	fd = open(INIT_RUNLEVEL_STATE, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
		  0644);
	if (fd < 0)
		return;
	if (write(fd, text, strlen(text)) < 0)
		notice("init: cannot record the runlevel: %s", strerror(errno));
	close(fd);
}

static void terminate(struct entry *entry, int grace)
{
	if (entry->pid <= 0 || entry->terminating)
		return;
	kill(entry->pid, SIGTERM);
	entry->terminating = 1;
	entry->kill_at = monotonic() + grace;
}

/*
 * Prepares the pass for a runlevel. Processes the new runlevel has no place
 * for are asked to leave now; the pass does not wait for them, because the
 * rc scripts are what stop services properly and these are the leftovers.
 */
static void set_runlevel(char level)
{
	struct entry *entry;

	prevlevel = runlevel;
	runlevel = level;
	notice("init: entering runlevel %c", runlevel);
	write_runlevel_state();

	for (entry = entries; entry; entry = entry->next) {
		entry->started_here = 0;
		entry->blocked_until = 0;
		if (entry->pid > 0 && !in_runlevel(entry, runlevel))
			terminate(entry, KILL_GRACE);
	}

	blocking = NULL;
	cursor = entries;
	phase = PH_RUNLEVEL;
}

static void reap_all(void);
static void final_shutdown(void);
static void reload_inittab(void);

static void advance(void)
{
	for (;;) {
		while (!blocking && cursor) {
			struct entry *entry = cursor;

			cursor = entry->next;
			if (!phase_matches(entry))
				continue;
			if (entry->pid > 0) {
				/* Still running from the runlevel this one
				 * replaced. It belongs here too, so record that
				 * the pass reached it and leave it alone. */
				entry->started_here = 1;
				continue;
			}
			/* A reload runs the pass again over a list that keeps
			 * this flag; a runlevel change clears it. So a "wait"
			 * or "once" entry that has already run in this runlevel
			 * is not run a second time by "telinit q". */
			if (entry->started_here && entry->action != A_RESPAWN)
				continue;
			if (entry->blocked_until)
				continue;
			if (spawn(entry) && phase_blocks(entry))
				blocking = entry;
		}
		if (blocking)
			return;

		switch (phase) {
		case PH_SYSINIT:
			phase = PH_BOOT;
			cursor = entries;
			continue;
		case PH_BOOT:
			set_runlevel(boot_runlevel);
			continue;
		case PH_RUNLEVEL:
			phase = PH_IDLE;
			if (runlevel == '0' || runlevel == '6')
				final_shutdown();
			if (reload_pending)
				reload_inittab();
			return;
		case PH_IDLE:
			return;
		}
	}
}

/*
 * Restarts what the runlevel says should be running. Only entries the pass has
 * already reached are considered, so a respawn entry that dies while an
 * earlier "wait" entry is still running does not jump the queue.
 */
static void maintain_respawns(void)
{
	struct entry *entry;
	long now = monotonic();

	for (entry = entries; entry; entry = entry->next) {
		if (entry->action != A_RESPAWN)
			continue;
		if (entry->pid > 0 || !entry->started_here)
			continue;
		if (!in_runlevel(entry, runlevel))
			continue;
		if (entry->blocked_until) {
			if (now < entry->blocked_until)
				continue;
			entry->blocked_until = 0;
			entry->start_count = 0;
		}
		spawn(entry);
	}
}

static void reap_all(void)
{
	for (;;) {
		struct entry *entry;
		pid_t pid;
		int status;

		pid = waitpid(-1, &status, WNOHANG);
		if (pid <= 0)
			return;

		for (entry = entries; entry; entry = entry->next) {
			if (entry->pid != pid)
				continue;
			entry->pid = 0;
			entry->terminating = 0;
			if (blocking == entry)
				blocking = NULL;
			break;
		}
	}
}

/*
 * Everything after the runlevel 0 or 6 scripts have run. System V left this to
 * /etc/init.d/halt and killall5; Sowa's init does it itself, because it is
 * the one process that is certain to still be there and it cannot be killed by
 * the sweep it is performing.
 */
static void final_shutdown(void)
{
	FILE *mounts;
	char *targets[256];
	int count = 0;
	int index;
	unsigned int how = runlevel == '6' ? RB_AUTOBOOT :
			   halt_instead_of_poweroff ? RB_HALT_SYSTEM :
			   RB_POWER_OFF;

	notice("init: sending all processes SIGTERM");
	kill(-1, SIGTERM);
	for (index = 0; index < shutdown_grace * 10; index++) {
		struct timespec tenth = { 0, 100 * 1000 * 1000 };

		reap_all();
		if (waitpid(-1, NULL, WNOHANG) < 0 && errno == ECHILD)
			break;
		nanosleep(&tenth, NULL);
	}
	notice("init: sending all processes SIGKILL");
	kill(-1, SIGKILL);

	sync();

	/*
	 * The mount table is read before anything is unmounted, since /proc is
	 * one of the things going away. Only real filesystems are unmounted:
	 * the virtual ones hold no data, and /dev and /run are still in use by
	 * this process.
	 */
	mounts = fopen("/proc/self/mounts", "re");
	if (mounts) {
		char line[4096];

		while (count < 256 && fgets(line, sizeof(line), mounts)) {
			char *source = strtok(line, " ");
			char *target = source ? strtok(NULL, " ") : NULL;
			char *type = target ? strtok(NULL, " ") : NULL;

			if (!type)
				continue;
			if (!strcmp(target, "/") || !strcmp(target, "/proc") ||
			    !strcmp(target, "/sys") || !strcmp(target, "/dev") ||
			    !strcmp(target, "/run") ||
			    !strcmp(type, "devtmpfs") || !strcmp(type, "devpts"))
				continue;
			targets[count++] = xstrdup(target);
		}
		fclose(mounts);
	}
	for (index = count - 1; index >= 0; index--) {
		if (umount2(targets[index], 0) == 0)
			continue;
		/* A lazy unmount still detaches the filesystem, and the sync
		 * above is what actually got the data onto it. */
		if (umount2(targets[index], MNT_DETACH) < 0)
			notice("init: cannot unmount %s: %s", targets[index],
			       strerror(errno));
	}

	/* Remounting the root read-only is what leaves an on-disk filesystem
	 * clean. On an initramfs there is nothing behind it and this fails,
	 * which is why the result is not reported. */
	sync();
	mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL);

	notice("init: %s", how == RB_AUTOBOOT ? "rebooting" :
			   how == RB_HALT_SYSTEM ? "halting" : "powering off");
	sync();
	reboot((int)how);

	/* reboot(2) only returns on failure, and there is nothing left to
	 * return to. */
	notice("init: cannot %s: %s", how == RB_AUTOBOOT ? "reboot" : "halt",
	       strerror(errno));
	for (;;)
		pause();
}

/*
 * A reload keeps what is running running. Entries are matched by id: an
 * unchanged one carries its process across, one whose command changed is asked
 * to stop so the pass starts it again, and one that is gone is stopped for
 * good.
 */
static void reload_inittab(void)
{
	struct entry *fresh = read_inittab();
	struct entry *entry;
	struct entry *old;
	struct entry *next;
	struct entry *tail;

	reload_pending = 0;
	if (!fresh) {
		notice("init: %s is unusable; keeping the running configuration",
		       INITTAB);
		return;
	}

	for (entry = fresh; entry; entry = entry->next) {
		int changed;

		for (old = entries; old; old = old->next) {
			if (strcmp(old->id, entry->id))
				continue;
			changed = strcmp(old->process, entry->process) != 0 ||
				  old->action != entry->action ||
				  old->own_tty != entry->own_tty;
			/* An entry that has already had its turn in this
			 * runlevel does not get another one, unless what it
			 * runs is not what it ran. */
			entry->started_here = changed ? 0 : old->started_here;
			if (old->pid > 0) {
				entry->pid = old->pid;
				entry->terminating = old->terminating;
				entry->kill_at = old->kill_at;
				old->pid = 0;
				if (changed)
					terminate(entry, KILL_GRACE);
			}
			break;
		}
	}

	/*
	 * An id that is gone from the file still has a process behind it. It is
	 * carried into the new list as an "off" entry - nothing ever starts one
	 * - so that the SIGKILL deadline is still serviced and the exit is
	 * still reaped. It is freed by the next reload, once it has stopped.
	 */
	for (tail = fresh; tail->next; tail = tail->next)
		;
	for (old = entries; old; old = next) {
		next = old->next;
		if (old->pid <= 0) {
			free(old->process);
			free(old);
			continue;
		}
		notice("init: id \"%s\" is gone from %s", old->id, INITTAB);
		old->action = A_OFF;
		terminate(old, KILL_GRACE);
		old->next = NULL;
		tail->next = old;
		tail = old;
	}

	entries = fresh;
	blocking = NULL;
	cursor = entries;
	phase = PH_RUNLEVEL;
	notice("init: reread %s", INITTAB);
	advance();
}

static void run_action_entries(enum action action)
{
	struct entry *entry;

	for (entry = entries; entry; entry = entry->next)
		if (entry->action == action && entry->pid <= 0)
			spawn(entry);
}

static void run_ondemand(char level)
{
	struct entry *entry;
	char lower = (char)tolower((unsigned char)level);

	for (entry = entries; entry; entry = entry->next)
		if (entry->action == A_ONDEMAND && entry->pid <= 0 &&
		    (strchr(entry->runlevels, level) ||
		     strchr(entry->runlevels, lower)))
			spawn(entry);
}

/*
 * The FIFO is opened read-write so init is its own last reader: a writer that
 * comes and goes never leaves a read end at EOF, and poll() reports the FIFO
 * readable only when there is a request in it.
 */
static void open_fifo(void)
{
	if (fifo_fd >= 0) {
		close(fifo_fd);
		fifo_fd = -1;
	}
	unlink(INIT_FIFO);
	if (mkfifo(INIT_FIFO, 0600) < 0 && errno != EEXIST) {
		notice("init: cannot create %s: %s", INIT_FIFO, strerror(errno));
		return;
	}
	fifo_fd = open(INIT_FIFO, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (fifo_fd < 0)
		notice("init: cannot open %s: %s", INIT_FIFO, strerror(errno));
}

static void handle_request(const struct init_request *request)
{
	char keyword[16];
	char level;

	if (request->magic != INIT_MAGIC)
		return;

	switch (request->cmd) {
	case INIT_CMD_RUNLVL:
		level = toupper(request->runlevel);
		if (level == 'Q') {
			reload_pending = 1;
			if (phase == PH_IDLE)
				reload_inittab();
			return;
		}
		if (strchr("ABC", level)) {
			/* An ondemand runlevel is not a runlevel: the entries
			 * that name it are run and the system stays where it
			 * is. */
			run_ondemand(level);
			return;
		}
		if (!strchr("0123456S", level)) {
			notice("init: ignoring a request for runlevel %c", level);
			return;
		}
		if (request->sleeptime > 0 && request->sleeptime <= 300)
			shutdown_grace = request->sleeptime;
		snprintf(keyword, sizeof(keyword), "%.*s",
			 (int)sizeof(keyword) - 1, request->data);
		halt_instead_of_poweroff = !strcmp(keyword, "halt");
		set_runlevel(level);
		advance();
		return;
	case INIT_CMD_POWERFAIL:
	case INIT_CMD_POWERFAILNOW:
		notice("init: power failure");
		run_action_entries(A_POWERFAIL);
		run_action_entries(A_POWERWAIT);
		return;
	case INIT_CMD_POWEROK:
		notice("init: power restored");
		run_action_entries(A_POWEROKWAIT);
		return;
	default:
		return;
	}
}

static void read_requests(void)
{
	struct init_request request;
	ssize_t got;

	while ((got = read(fifo_fd, &request, sizeof(request))) > 0) {
		if ((size_t)got != sizeof(request))
			continue;
		/* One request can change the runlevel, which is the last thing
		 * this loop should do with a stale view of the world. */
		handle_request(&request);
		return;
	}
	if (got < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
		open_fifo();
}

/*
 * The runlevel init was asked for on the kernel command line. The kernel hands
 * init every command line word it did not recognise and that has no "=" in it,
 * which is how "single" has reached init since the beginning.
 */
static char runlevel_from_argv(int argc, char **argv, int *emergency)
{
	int index;
	char level = 0;

	for (index = 1; index < argc; index++) {
		const char *word = argv[index];

		if (!strcmp(word, "single") || !strcmp(word, "-s") ||
		    !strcmp(word, "s") || !strcmp(word, "S"))
			level = 'S';
		else if (!strcmp(word, "emergency") || !strcmp(word, "-b"))
			*emergency = 1;
		else if (word[0] >= '0' && word[0] <= '6' && !word[1])
			level = word[0];
	}
	return level;
}

/* Not PID 1: init is telinit under another name, the way it always was. */
static int forward_to_init(int argc, char **argv)
{
	int emergency = 0;
	char level = runlevel_from_argv(argc, argv, &emergency);

	if (!level) {
		fprintf(stderr, "usage: init {0|1|2|3|4|5|6|S|single}\n");
		return 1;
	}
	return init_request_send(INIT_CMD_RUNLVL, level, 0, NULL) < 0 ? 1 : 0;
}

int main(int argc, char **argv)
{
	sigset_t handled;
	struct pollfd fds[2];
	int signal_fd;
	int emergency = 0;
	char requested;

	if (getpid() != 1)
		return forward_to_init(argc, argv);

	umask(022);
	setsid();
	open_console();
	notice("init: sowa-init " VERSION " starting");

	/*
	 * Every signal init acts on is blocked and read from a signalfd
	 * instead, so a child that exits while init is deciding what to do
	 * about the last one cannot be missed.
	 */
	sigemptyset(&handled);
	sigaddset(&handled, SIGCHLD);
	sigaddset(&handled, SIGINT);	/* Ctrl-Alt-Del, from the kernel  */
	sigaddset(&handled, SIGPWR);	/* a UPS daemon, or telinit       */
	sigaddset(&handled, SIGHUP);	/* reread the inittab             */
	sigaddset(&handled, SIGUSR1);	/* recreate the control FIFO      */
	sigaddset(&handled, SIGWINCH);	/* the kernel's KeyboardSignal    */
	sigaddset(&handled, SIGTERM);
	sigprocmask(SIG_BLOCK, &handled, NULL);
	signal(SIGPIPE, SIG_IGN);

	signal_fd = signalfd(-1, &handled, SFD_CLOEXEC | SFD_NONBLOCK);
	if (signal_fd < 0) {
		notice("init: cannot create a signalfd: %s", strerror(errno));
		for (;;)
			pause();
	}

	open_fifo();

	entries = read_inittab();
	if (!entries)
		entries = emergency_inittab(INITTAB " has no usable entries");

	requested = runlevel_from_argv(argc, argv, &emergency);
	boot_runlevel = requested ? requested : initdefault_runlevel();
	if (!boot_runlevel) {
		notice("init: no initdefault in %s; entering runlevel 3", INITTAB);
		boot_runlevel = '3';
	}
	if (!requested && (boot_runlevel == '0' || boot_runlevel == '6')) {
		/* An initdefault of 0 or 6 is a machine that shuts itself down
		 * as soon as it has finished starting. */
		notice("init: initdefault is %c; entering runlevel 3 instead",
		       boot_runlevel);
		boot_runlevel = '3';
	}
	if (emergency) {
		/* Ahead of the boot entries, waited on like one of them: the
		 * shell runs after sysinit has mounted /proc and /dev, and the
		 * boot continues into the default runlevel when it exits. */
		struct entry *shell = emergency_inittab("emergency boot requested");

		shell->action = A_BOOTWAIT;
		shell->next = entries;
		entries = shell;
	}

	write_runlevel_state();
	cursor = entries;
	phase = PH_SYSINIT;
	advance();

	for (;;) {
		struct entry *entry;
		long now;
		int timeout = -1;
		int ready;

		maintain_respawns();

		now = monotonic();
		for (entry = entries; entry; entry = entry->next) {
			long deadline = 0;

			if (entry->terminating && entry->pid > 0)
				deadline = entry->kill_at;
			else if (entry->blocked_until)
				deadline = entry->blocked_until;
			if (!deadline)
				continue;
			if (deadline <= now)
				timeout = 0;
			else if (timeout < 0 || (deadline - now) * 1000 < timeout)
				timeout = (int)((deadline - now) * 1000);
		}

		fds[0].fd = signal_fd;
		fds[0].events = POLLIN;
		fds[1].fd = fifo_fd;
		fds[1].events = POLLIN;
		ready = poll(fds, fifo_fd >= 0 ? 2 : 1, timeout);

		now = monotonic();
		for (entry = entries; entry; entry = entry->next)
			if (entry->terminating && entry->pid > 0 &&
			    entry->kill_at <= now) {
				kill(entry->pid, SIGKILL);
				entry->terminating = 0;
			}

		if (ready <= 0)
			continue;

		if (fds[0].revents & POLLIN) {
			struct signalfd_siginfo info;

			while (read(signal_fd, &info, sizeof(info)) ==
			       sizeof(info)) {
				switch (info.ssi_signo) {
				case SIGCHLD:
					reap_all();
					advance();
					break;
				case SIGINT:
					notice("init: Ctrl-Alt-Del");
					run_action_entries(A_CTRLALTDEL);
					break;
				case SIGPWR:
					handle_request(&(struct init_request){
						.magic = INIT_MAGIC,
						.cmd = INIT_CMD_POWERFAIL });
					break;
				case SIGWINCH:
					run_action_entries(A_KBREQUEST);
					break;
				case SIGHUP:
					reload_pending = 1;
					if (phase == PH_IDLE)
						reload_inittab();
					break;
				case SIGUSR1:
					/* rc.sysinit mounts a tmpfs over /run,
					 * which takes the FIFO with it. */
					open_fifo();
					write_runlevel_state();
					break;
				case SIGTERM:
					notice("init: SIGTERM ignored; use telinit or shutdown");
					break;
				default:
					break;
				}
			}
		}

		if (fifo_fd >= 0 && (fds[1].revents & POLLIN))
			read_requests();
	}
}
