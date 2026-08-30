/*
 * Sending a request to init. Shared by telinit, shutdown, halt and by init
 * itself when it is run as something other than PID 1.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "initreq.h"

/*
 * The FIFO is opened non-blocking so a machine whose init has stopped reading
 * gives an error rather than an unkillable command. init keeps a writer of its
 * own open on it, so O_WRONLY never fails with ENXIO while init is alive.
 */
int init_request_send(int cmd, int runlevel, int sleeptime, const char *data)
{
	struct init_request request;
	const char *path = INIT_FIFO;
	int fd;

	memset(&request, 0, sizeof(request));
	request.magic = INIT_MAGIC;
	request.cmd = cmd;
	request.runlevel = runlevel;
	request.sleeptime = sleeptime;
	if (data)
		snprintf(request.data, sizeof(request.data), "%s", data);

	signal(SIGPIPE, SIG_IGN);
	fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		path = INIT_FIFO_COMPAT;
		fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	}
	if (fd < 0) {
		fprintf(stderr, "cannot reach init on %s: %s\n", INIT_FIFO,
			strerror(errno));
		return -1;
	}
	if (write(fd, &request, sizeof(request)) != (ssize_t)sizeof(request)) {
		fprintf(stderr, "cannot send the request to init: %s\n",
			strerror(errno));
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}

/*
 * The runlevel init recorded, as the two characters runlevel(8) prints.
 * Returns 0 when the state file is not there, which is what a system whose
 * init has not reached a runlevel yet looks like.
 */
int init_read_runlevel(char *previous, char *current)
{
	FILE *file = fopen(INIT_RUNLEVEL_STATE, "re");
	char from;
	char to;

	if (!file)
		return 0;
	if (fscanf(file, "%c %c", &from, &to) != 2) {
		fclose(file);
		return 0;
	}
	fclose(file);
	*previous = from;
	*current = to;
	return 1;
}
