/*
 * halt, poweroff and reboot - one program, told apart by the name it is run
 * under, exactly as System V's were.
 *
 * Outside runlevels 0 and 6 these are a polite way of spelling shutdown: the
 * request goes to init, which stops the services and takes the machine down in
 * order. Inside runlevel 0 or 6 the shutdown is already happening and the
 * kernel call is made directly, which is also what -f asks for from anywhere.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <unistd.h>

#include "initreq.h"

#define SHUTDOWN "/sbin/shutdown"

static void usage(const char *name, int status)
{
	fprintf(status ? stderr : stdout,
		"usage: %s [-f] [-p] [-n]\n"
		"\n"
		"  -f  do it now, without asking init to stop anything first\n"
		"  -p  power off rather than halt (halt only)\n"
		"  -n  do not sync before the kernel call\n",
		name);
	exit(status);
}

int main(int argc, char **argv)
{
	char *name = basename(argv[0]);
	int force = 0;
	int poweroff_wanted = 0;
	int no_sync = 0;
	int option;
	unsigned int how;
	char previous;
	char current;

	while ((option = getopt(argc, argv, "fpnwdih")) != -1) {
		switch (option) {
		case 'f':
			force = 1;
			break;
		case 'p':
			poweroff_wanted = 1;
			break;
		case 'n':
			no_sync = 1;
			break;
		/* Accepted and ignored: nothing here writes wtmp, and there
		 * are no network interfaces or modules to take down first. */
		case 'w':
		case 'd':
		case 'i':
			break;
		case 'h':
			usage(name, 0);
			break;
		default:
			usage(name, 1);
		}
	}

	if (geteuid() != 0) {
		fprintf(stderr, "%s: only root can do that\n", name);
		return 1;
	}

	if (!strcmp(name, "reboot"))
		how = RB_AUTOBOOT;
	else if (!strcmp(name, "poweroff") || poweroff_wanted)
		how = RB_POWER_OFF;
	else
		how = RB_HALT_SYSTEM;

	/*
	 * init is already taking the system down when the runlevel is 0 or 6,
	 * so this is the last step of that shutdown rather than the start of a
	 * new one. Sowa's init performs that step itself, so reaching here in
	 * runlevel 0 or 6 means someone ran the command by hand; do what they
	 * asked rather than ask init for a runlevel it is already in.
	 */
	if (!force && init_read_runlevel(&previous, &current) &&
	    current != '0' && current != '6') {
		char *shutdown_argv[4];

		shutdown_argv[0] = (char *)"shutdown";
		shutdown_argv[1] = (char *)(how == RB_AUTOBOOT ? "-r" :
					    how == RB_POWER_OFF ? "-P" : "-H");
		shutdown_argv[2] = (char *)"now";
		shutdown_argv[3] = NULL;
		execv(SHUTDOWN, shutdown_argv);
		fprintf(stderr, "%s: cannot run %s: %s\n", name, SHUTDOWN,
			strerror(errno));
		return 1;
	}

	if (!no_sync)
		sync();
	reboot((int)how);
	fprintf(stderr, "%s: %s\n", name, strerror(errno));
	return 1;
}
