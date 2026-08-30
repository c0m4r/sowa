/*
 * telinit - ask init for a runlevel.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "initreq.h"

static void usage(int status)
{
	fprintf(status ? stderr : stdout,
		"usage: telinit [-t SECONDS] {0|1|2|3|4|5|6|S|s|Q|q|a|b|c}\n"
		"\n"
		"  0        halt or power the system off\n"
		"  1, S, s  single user, a root shell on the console\n"
		"  2-5      multi user; 3 is the Sowa default\n"
		"  6        reboot\n"
		"  Q, q     reread /etc/inittab without changing the runlevel\n"
		"  a, b, c  run the ondemand entries for that letter\n"
		"  -t SEC   seconds between SIGTERM and SIGKILL at shutdown\n");
	exit(status);
}

int main(int argc, char **argv)
{
	int sleeptime = 0;
	int option;
	char level;

	while ((option = getopt(argc, argv, "t:h")) != -1) {
		switch (option) {
		case 't':
			sleeptime = atoi(optarg);
			break;
		case 'h':
			usage(0);
			break;
		default:
			usage(1);
		}
	}

	if (optind != argc - 1 || strlen(argv[optind]) != 1)
		usage(1);

	level = argv[optind][0];
	if (!strchr("0123456SsQqAaBbCc", level)) {
		fprintf(stderr, "telinit: %c is not a runlevel\n", level);
		return 1;
	}
	level = (char)toupper((unsigned char)level);

	if (geteuid() != 0) {
		fprintf(stderr, "telinit: only root can change the runlevel\n");
		return 1;
	}

	return init_request_send(INIT_CMD_RUNLVL, level, sleeptime, NULL) < 0;
}
