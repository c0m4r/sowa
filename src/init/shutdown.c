/*
 * shutdown - bring the system down at a stated time.
 *
 * The work itself belongs to init: shutdown waits out the delay, tells the
 * console what is about to happen, and then asks for runlevel 0 or 6. It stays
 * in the foreground while it waits, so a delayed shutdown is a process you can
 * see and interrupt; "shutdown -c" finds it through /run/shutdown.pid.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "initreq.h"

#define PIDFILE "/run/shutdown.pid"
#define CONSOLE "/dev/console"

static volatile sig_atomic_t cancelled;

static void usage(int status)
{
	fprintf(status ? stderr : stdout,
		"usage: shutdown [-rhHPkc] [-t SECONDS] TIME [MESSAGE]\n"
		"\n"
		"  -r         reboot\n"
		"  -h         power the system off (halt with -H)\n"
		"  -H         halt without powering off\n"
		"  -P         power the system off\n"
		"  -k         announce the shutdown but do not perform it\n"
		"  -c         cancel a shutdown that is waiting\n"
		"  -t SECONDS seconds between SIGTERM and SIGKILL (default 3)\n"
		"\n"
		"TIME is \"now\", \"+MINUTES\" or \"HH:MM\".\n");
	exit(status);
}

static void catch_signal(int signal_number)
{
	(void)signal_number;
	cancelled = 1;
}

/*
 * Warnings go to the console. System V wrote to every logged-in terminal,
 * which it found in utmp; nothing on a Sowa system writes utmp, so the
 * console is where an announcement can actually be counted on to appear.
 */
static void announce(const char *fmt, ...)
{
	char message[512];
	const char *terminal;
	va_list args;
	int fd;

	va_start(args, fmt);
	vsnprintf(message, sizeof(message), fmt, args);
	va_end(args);

	/* Whoever asked for the shutdown sees it wherever they are. */
	fprintf(stderr, "%s\n", message);

	terminal = ttyname(STDERR_FILENO);
	if (terminal && !strcmp(terminal, CONSOLE))
		return;
	fd = open(CONSOLE, O_WRONLY | O_NOCTTY | O_CLOEXEC);
	if (fd >= 0) {
		dprintf(fd, "\r\n%s\r\n", message);
		close(fd);
	}
}

static long parse_time(const char *text)
{
	struct tm wanted;
	time_t now;
	long hour;
	long minute;
	char *end;

	if (!strcmp(text, "now"))
		return 0;

	if (*text == '+') {
		long minutes = strtol(text + 1, &end, 10);

		if (*end || minutes < 0)
			return -1;
		return minutes * 60;
	}

	hour = strtol(text, &end, 10);
	if (*end != ':')
		return -1;
	minute = strtol(end + 1, &end, 10);
	if (*end || hour < 0 || hour > 23 || minute < 0 || minute > 59)
		return -1;

	now = time(NULL);
	localtime_r(&now, &wanted);
	wanted.tm_hour = (int)hour;
	wanted.tm_min = (int)minute;
	wanted.tm_sec = 0;
	wanted.tm_isdst = -1;
	{
		time_t when = mktime(&wanted);

		if (when == (time_t)-1)
			return -1;
		/* A time that has already passed today means tomorrow. */
		if (when <= now)
			when += 24 * 60 * 60;
		return (long)(when - now);
	}
}

static void remove_pidfile(void)
{
	unlink(PIDFILE);
}

static int cancel_pending(void)
{
	FILE *file = fopen(PIDFILE, "re");
	long pid;

	if (!file) {
		fprintf(stderr, "shutdown: no shutdown is waiting\n");
		return 1;
	}
	if (fscanf(file, "%ld", &pid) != 1 || pid <= 1) {
		fclose(file);
		fprintf(stderr, "shutdown: %s is unreadable\n", PIDFILE);
		return 1;
	}
	fclose(file);
	if (kill((pid_t)pid, SIGINT) < 0) {
		fprintf(stderr, "shutdown: cannot signal process %ld: %s\n", pid,
			strerror(errno));
		remove_pidfile();
		return 1;
	}
	return 0;
}

static void write_pidfile(void)
{
	FILE *file = fopen(PIDFILE, "we");

	if (!file)
		return;
	fprintf(file, "%ld\n", (long)getpid());
	fclose(file);
}

/* The remaining times an announcement is worth making, in seconds. */
static int worth_announcing(long remaining)
{
	static const long marks[] = { 3600, 1800, 900, 600, 300, 120, 60, 30,
				      10, 5, 4, 3, 2, 1, 0 };
	int index;

	for (index = 0; marks[index]; index++)
		if (remaining == marks[index])
			return 1;
	return 0;
}

static void describe(long remaining, const char *what, const char *message)
{
	if (remaining >= 120)
		announce("The system is going down for %s in %ld minutes!%s%s",
			 what, remaining / 60, message ? " " : "",
			 message ? message : "");
	else if (remaining > 0)
		announce("The system is going down for %s in %ld seconds!%s%s",
			 what, remaining, message ? " " : "",
			 message ? message : "");
	else
		announce("The system is going down for %s NOW!%s%s", what,
			 message ? " " : "", message ? message : "");
}

int main(int argc, char **argv)
{
	const char *message = NULL;
	const char *what;
	int reboot_wanted = 0;
	int halt_wanted = 0;
	int stop_wanted = 0;
	int announce_only = 0;
	int grace = 3;
	int option;
	long remaining;

	while ((option = getopt(argc, argv, "rhHPkct:afFnq")) != -1) {
		switch (option) {
		case 'r':
			reboot_wanted = 1;
			break;
		case 'h':
		case 'P':
			stop_wanted = 1;
			break;
		case 'H':
			stop_wanted = 1;
			halt_wanted = 1;
			break;
		case 'k':
			announce_only = 1;
			break;
		case 'c':
			return cancel_pending();
		case 't':
			grace = atoi(optarg);
			break;
		/* Accepted and ignored: there is no fsck to force or skip, and
		 * nothing here writes wtmp. */
		case 'a':
		case 'f':
		case 'F':
		case 'n':
		case 'q':
			break;
		default:
			usage(1);
		}
	}

	if (optind >= argc)
		usage(1);

	remaining = parse_time(argv[optind]);
	if (remaining < 0) {
		fprintf(stderr, "shutdown: %s is not a time\n", argv[optind]);
		return 1;
	}
	if (optind + 1 < argc)
		message = argv[optind + 1];

	if (geteuid() != 0) {
		fprintf(stderr, "shutdown: only root can shut the system down\n");
		return 1;
	}

	/* Without -r or -h the system goes to single user mode, which is what
	 * System V's shutdown has always done with a bare time argument. */
	what = reboot_wanted ? "reboot" :
	       !stop_wanted ? "maintenance" :
	       halt_wanted ? "halt" : "power off";

	if (remaining > 0) {
		struct sigaction action;

		memset(&action, 0, sizeof(action));
		action.sa_handler = catch_signal;
		sigaction(SIGINT, &action, NULL);
		sigaction(SIGTERM, &action, NULL);
		write_pidfile();
		describe(remaining, what, message);
	}

	while (remaining > 0) {
		if (sleep(1) > 0 && !cancelled)
			continue;
		if (cancelled) {
			announce("Shutdown cancelled.");
			remove_pidfile();
			return 0;
		}
		remaining--;
		if (worth_announcing(remaining))
			describe(remaining, what, message);
	}

	remove_pidfile();
	if (announce_only)
		return 0;

	describe(0, what, message);
	return init_request_send(INIT_CMD_RUNLVL,
				 reboot_wanted ? '6' : stop_wanted ? '0' : '1',
				 grace, halt_wanted ? "halt" : "poweroff") < 0;
}
