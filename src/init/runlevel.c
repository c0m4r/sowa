/*
 * runlevel - print the previous and current runlevel.
 *
 * System V's read the RUN_LVL record out of utmp. glibc 2.42 removed the
 * functions that wrote utmp, so nothing on a Sowa system produces that record
 * and init keeps the runlevel in a file of its own instead. The output is
 * unchanged: "<previous> <current>", with N for "there was no previous one".
 */

#define _GNU_SOURCE

#include <stdio.h>

#include "initreq.h"

int main(void)
{
	char previous;
	char current;

	if (!init_read_runlevel(&previous, &current)) {
		printf("unknown\n");
		return 1;
	}
	printf("%c %c\n", previous, current);
	return 0;
}
