/*
 * The control channel between init and the programs that ask it for
 * something: telinit, shutdown, halt, poweroff and reboot.
 *
 * The request structure is the one System V init has used for decades, so a
 * message is 384 bytes with the same field order and the same magic number.
 * Keeping the wire format means a Sowa system can be driven by anything that
 * already knows how to talk to /run/initctl, and that the format is documented
 * somewhere other than this header.
 *
 * One extension is ours: on a request that asks for runlevel 0, the data area
 * may carry the keyword "halt" or "poweroff". System V left that decision to
 * the halt script, and Sowa's init performs the last phase of shutdown
 * itself, so it has to be told which of the two the caller meant. An empty
 * data area means poweroff, which is what a machine without a UPS wants.
 */

#ifndef SOWA_INITREQ_H
#define SOWA_INITREQ_H

#define INIT_MAGIC 0x03091969

#define INIT_CMD_START 0
#define INIT_CMD_RUNLVL 1
#define INIT_CMD_POWERFAIL 2
#define INIT_CMD_POWERFAILNOW 3
#define INIT_CMD_POWEROK 4
#define INIT_CMD_SETENV 6
#define INIT_CMD_UNSETENV 7

#define INIT_REQUEST_DATA 368

struct init_request {
	int magic;			/* INIT_MAGIC, or the message is ignored */
	int cmd;			/* one of INIT_CMD_*                     */
	int runlevel;			/* the runlevel character, for RUNLVL    */
	int sleeptime;			/* seconds between SIGTERM and SIGKILL   */
	char data[INIT_REQUEST_DATA];	/* "halt" or "poweroff"; see above       */
};

/*
 * The FIFO lives on /run because /dev is a devtmpfs the kernel populates and
 * rc.sysinit mounts over: a node created there before the mount would be
 * hidden by it. /dev/initctl is a symlink to this path, for the fingers that
 * have typed it for thirty years.
 */
#define INIT_FIFO "/run/initctl"
#define INIT_FIFO_COMPAT "/dev/initctl"

/*
 * Where init records the runlevel, as "<previous> <current>\n". glibc no
 * longer writes utmp - the functions that did were removed in 2.42 - so
 * runlevel(8) cannot read the RUN_LVL record the way System V's did, and this
 * file is what it reads instead.
 */
#define INIT_RUNLEVEL_STATE "/run/initrunlevel"

/* request.c */
int init_request_send(int cmd, int runlevel, int sleeptime, const char *data);
int init_read_runlevel(char *previous, char *current);

#endif /* SOWA_INITREQ_H */
