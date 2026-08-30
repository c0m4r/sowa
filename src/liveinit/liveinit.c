/*
 * sowa-liveinit - the early userspace of the Sowa live medium.
 *
 * The kernel unpacks the initramfs into a ramfs and runs /init, which is this
 * program. Its whole job is to turn "a kernel with a 1 MB ramfs" into "a
 * kernel whose root filesystem is the squashfs on the medium it booted from",
 * and then get out of the way:
 *
 *     find the medium  ->  losetup the squashfs  ->  mount it read-only
 *                      ->  overlay a tmpfs on top of it
 *                      ->  switch_root into it and exec /sbin/init
 *
 * The mounted squashfs design keeps memory use bounded. Sowa used to pack the
 * entire root filesystem into the initramfs, so the kernel unpacked a gigabyte
 * of files into a ramfs whose pages can never be reclaimed - the live system
 * needed three times the tree in RAM before it had any working space, and a
 * machine given less did not fail cleanly: the unpack stopped part way and the
 * boot continued on a truncated tree. Here the root filesystem stays
 * compressed on the medium and is read through the page cache, which the
 * kernel can evict, so what the live system costs is the writable layer plus
 * whatever it is currently reading.
 *
 * There is no shell in this initramfs and nothing else to fall back on, which
 * is a deliberate trade: it is what keeps the image at one static binary
 * instead of twenty megabytes of Bash, util-linux and glibc. Every failure
 * here is therefore fatal and has to say enough on the console to be diagnosed
 * without a prompt - see fatal() and the device list it prints.
 *
 * Kernel command line (everything is optional; the ISO sets the first two):
 *
 *   sowa.id=HEX          the medium's identity. The stage that builds the ISO
 *                        names a zero-byte marker file after the SHA-256 of
 *                        the squashfs, and this is what is searched for. Two
 *                        different Sowa media therefore cannot be confused for
 *                        one another, and two copies of the same medium are
 *                        interchangeable because they carry the same payload.
 *   sowa.basedir=DIR     top-level directory on the medium (default "sowa")
 *   copytoram=auto|y|n   copy the squashfs into RAM before mounting it
 *                        (default auto - see decide_copy_to_ram)
 *   cow_spacesize=SIZE   size= for the writable overlay tmpfs, e.g. 512M.
 *                        The default is tmpfs's own: half of RAM.
 *   checksum=y           verify the squashfs against its .sha256 before
 *                        mounting it (default off; it reads the whole image)
 *   img_loop=PATH        boot from an ISO stored as a file rather than from a
 *                        medium: PATH is looked for on every block device
 *   img_dev=DEVICE       restrict that search to one device
 *   rootdelay=SECONDS    how long to wait for the medium to appear (default 30)
 *
 * Anything the kernel does not recognise and this program does not claim is
 * passed on to /sbin/init, so "single" on the ISO's command line still reaches
 * it as an argument.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <linux/loop.h>

#ifndef VERSION
#define VERSION "0.1"
#endif

/* The architecture directory on the medium. It is a compile-time value because
 * the medium is built for one architecture and this binary ships on it. */
#ifndef LIVE_ARCH
#define LIVE_ARCH "x86_64"
#endif

#define DEFAULT_BASEDIR "sowa"
#define SFS_NAME "root.sfs"

#define RUN_DIR "/run/sowa"
#define MEDIUM_MNT RUN_DIR "/medium"
#define IMG_MNT RUN_DIR "/img"
#define RAM_MNT RUN_DIR "/ram"
#define SFS_MNT RUN_DIR "/sfs"
#define COW_MNT RUN_DIR "/cow"
#define NEW_ROOT "/new_root"

#define SYS_BLOCK "/sys/class/block"

/* A kernel block device name and the /dev path built from it. Both are fixed
 * so that every buffer holding one is provably large enough. */
#define DEVICE_NAME_MAX 64
#define DEVICE_PATH_MAX (DEVICE_NAME_MAX + 8)

/* Long enough for a USB controller to enumerate a stick, which is the slowest
 * medium this has to wait for and routinely takes several seconds. */
#define DEFAULT_ROOTDELAY 30

/* How long a fatal message stays on the console before the machine reboots.
 * Rebooting rather than hanging is what makes an unattended machine recover
 * from a medium that was not ready; the delay is what makes the message
 * readable by someone standing in front of it. */
#define FATAL_PAUSE 30

/* Copy the squashfs to RAM only if this much memory is left over afterwards.
 * A live system with no headroom past its own root filesystem is not one
 * anything can be done on. */
#define COPYTORAM_HEADROOM_KIB (2ULL * 1024 * 1024)
/* An image this size or larger is never copied, however much memory the
 * machine reports: past a few gigabytes the copy takes longer than the boot it
 * is meant to speed up. */
#define COPYTORAM_MAX_BYTES (4ULL * 1024 * 1024 * 1024)

#define COPY_BUFFER (1024 * 1024)

/* ------------------------------------------------------------------ output */

static void msg(const char *fmt, ...)
{
	va_list args;

	fputs(":: ", stdout);
	va_start(args, fmt);
	vfprintf(stdout, fmt, args);
	va_end(args);
	fputc('\n', stdout);
	fflush(stdout);
}

/* Everything known about where the medium was looked for, printed by fatal()
 * because there is no shell here to ask afterwards. */
static char examined[4096];

static void note_examined(const char *fmt, ...)
{
	va_list args;
	size_t used = strlen(examined);

	if (used + 80 >= sizeof(examined))
		return;
	va_start(args, fmt);
	vsnprintf(examined + used, sizeof(examined) - used, fmt, args);
	va_end(args);
}

static void fatal(const char *fmt, ...)
{
	va_list args;
	struct timespec pause = { .tv_sec = FATAL_PAUSE, .tv_nsec = 0 };

	fputs("\n", stdout);
	fputs("liveinit: cannot boot this medium\n", stdout);
	fputs("liveinit: ", stdout);
	va_start(args, fmt);
	vfprintf(stdout, fmt, args);
	va_end(args);
	fputc('\n', stdout);
	if (examined[0] != '\0') {
		fputs("liveinit: block devices examined:\n", stdout);
		fputs(examined, stdout);
	}
	fprintf(stdout, "liveinit: rebooting in %d seconds\n", FATAL_PAUSE);
	fflush(stdout);

	nanosleep(&pause, NULL);
	sync();
	reboot(RB_AUTOBOOT);
	/* reboot(2) only returns when it fails, and there is nothing left to
	 * try: exiting makes the kernel panic, which panic=-1 turns into the
	 * reboot that was wanted anyway. */
	_exit(1);
}

/* ------------------------------------------------------------ small helpers */

static void mkdir_p(const char *path)
{
	char work[PATH_MAX];
	char *slash;

	if (strlen(path) >= sizeof(work))
		fatal("path is too long: %s", path);
	strcpy(work, path);

	for (slash = work + 1; *slash != '\0'; slash++) {
		if (*slash != '/')
			continue;
		*slash = '\0';
		if (mkdir(work, 0755) != 0 && errno != EEXIST)
			fatal("cannot create %s: %s", work, strerror(errno));
		*slash = '/';
	}
	if (mkdir(work, 0755) != 0 && errno != EEXIST)
		fatal("cannot create %s: %s", path, strerror(errno));
}

/* Reads a whole small file - a sysfs attribute, /proc/cmdline - and trims the
 * trailing newline. Returns false when it cannot be read at all. */
static bool read_small_file(const char *path, char *buffer, size_t size)
{
	int fd;
	ssize_t got;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;
	got = read(fd, buffer, size - 1);
	close(fd);
	if (got < 0)
		return false;
	while (got > 0 && (buffer[got - 1] == '\n' || buffer[got - 1] == '\r'))
		got--;
	buffer[got] = '\0';
	return true;
}

static bool path_exists(const char *path)
{
	struct stat info;

	return stat(path, &info) == 0;
}

static void sleep_ms(long milliseconds)
{
	struct timespec duration = {
		.tv_sec = milliseconds / 1000,
		.tv_nsec = (milliseconds % 1000) * 1000000L,
	};

	nanosleep(&duration, NULL);
}

/* ----------------------------------------------------------- kernel cmdline */

#define MAX_ARGS 256

static char cmdline[4096];
static char *cmdline_args[MAX_ARGS];
static int cmdline_count;

static void cmdline_read(void)
{
	char *cursor;

	if (!read_small_file("/proc/cmdline", cmdline, sizeof(cmdline)))
		return;

	for (cursor = cmdline; *cursor != '\0';) {
		while (*cursor == ' ' || *cursor == '\t')
			cursor++;
		if (*cursor == '\0')
			break;
		if (cmdline_count == MAX_ARGS)
			break;
		cmdline_args[cmdline_count++] = cursor;
		while (*cursor != '\0' && *cursor != ' ' && *cursor != '\t')
			cursor++;
		if (*cursor != '\0')
			*cursor++ = '\0';
	}
}

/* The value of key=value, or fallback when the parameter is absent. A bare
 * parameter with no "=" yields an empty string, which is how "checksum" and
 * "checksum=y" end up meaning the same thing. */
static const char *cmdline_get(const char *key, const char *fallback)
{
	size_t length = strlen(key);
	int index;

	for (index = 0; index < cmdline_count; index++) {
		const char *arg = cmdline_args[index];

		if (strncmp(arg, key, length) != 0)
			continue;
		if (arg[length] == '=')
			return arg + length + 1;
		if (arg[length] == '\0')
			return "";
	}
	return fallback;
}

static bool cmdline_enabled(const char *key)
{
	const char *value = cmdline_get(key, NULL);

	if (value == NULL)
		return false;
	return value[0] == '\0' || strcmp(value, "y") == 0 ||
	       strcmp(value, "yes") == 0 || strcmp(value, "1") == 0;
}

/* --------------------------------------------------------------- SHA-256 */

/* checksum=y reads the whole image, so this is deliberately the plain
 * implementation rather than anything clever: it runs once, at boot, on a file
 * that is already the bottleneck. */

struct sha256 {
	uint32_t state[8];
	uint64_t length;
	uint8_t block[64];
	size_t held;
};

static const uint32_t sha256_k[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
	0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
	0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
	0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
	0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
	0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
	0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
	0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
	0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t rotate_right(uint32_t value, int bits)
{
	return (value >> bits) | (value << (32 - bits));
}

static void sha256_block(struct sha256 *context, const uint8_t *block)
{
	uint32_t w[64];
	uint32_t a, b, c, d, e, f, g, h;
	int index;

	for (index = 0; index < 16; index++)
		w[index] = ((uint32_t)block[index * 4] << 24) |
			   ((uint32_t)block[index * 4 + 1] << 16) |
			   ((uint32_t)block[index * 4 + 2] << 8) |
			   ((uint32_t)block[index * 4 + 3]);
	for (index = 16; index < 64; index++) {
		uint32_t s0 = rotate_right(w[index - 15], 7) ^
			      rotate_right(w[index - 15], 18) ^
			      (w[index - 15] >> 3);
		uint32_t s1 = rotate_right(w[index - 2], 17) ^
			      rotate_right(w[index - 2], 19) ^
			      (w[index - 2] >> 10);
		w[index] = w[index - 16] + s0 + w[index - 7] + s1;
	}

	a = context->state[0];
	b = context->state[1];
	c = context->state[2];
	d = context->state[3];
	e = context->state[4];
	f = context->state[5];
	g = context->state[6];
	h = context->state[7];

	for (index = 0; index < 64; index++) {
		uint32_t s1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^
			      rotate_right(e, 25);
		uint32_t ch = (e & f) ^ (~e & g);
		uint32_t t1 = h + s1 + ch + sha256_k[index] + w[index];
		uint32_t s0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^
			      rotate_right(a, 22);
		uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
		uint32_t t2 = s0 + maj;

		h = g;
		g = f;
		f = e;
		e = d + t1;
		d = c;
		c = b;
		b = a;
		a = t1 + t2;
	}

	context->state[0] += a;
	context->state[1] += b;
	context->state[2] += c;
	context->state[3] += d;
	context->state[4] += e;
	context->state[5] += f;
	context->state[6] += g;
	context->state[7] += h;
}

static void sha256_init(struct sha256 *context)
{
	static const uint32_t initial[8] = {
		0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
		0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
	};

	memcpy(context->state, initial, sizeof(initial));
	context->length = 0;
	context->held = 0;
}

static void sha256_update(struct sha256 *context, const uint8_t *data,
			  size_t size)
{
	context->length += size;
	while (size > 0) {
		size_t room = 64 - context->held;
		size_t take = size < room ? size : room;

		memcpy(context->block + context->held, data, take);
		context->held += take;
		data += take;
		size -= take;
		if (context->held == 64) {
			sha256_block(context, context->block);
			context->held = 0;
		}
	}
}

static void sha256_final(struct sha256 *context, char *hex)
{
	uint64_t bits = context->length * 8;
	uint8_t tail[8];
	uint8_t pad = 0x80;
	uint8_t zero = 0x00;
	int index;

	sha256_update(context, &pad, 1);
	while (context->held != 56)
		sha256_update(context, &zero, 1);
	for (index = 0; index < 8; index++)
		tail[index] = (uint8_t)(bits >> (56 - index * 8));
	sha256_update(context, tail, sizeof(tail));

	for (index = 0; index < 8; index++)
		sprintf(hex + index * 8, "%08x", context->state[index]);
	hex[64] = '\0';
}

/* Hex SHA-256 of a file, into a 65-byte buffer. */
static bool sha256_file(const char *path, char *hex)
{
	struct sha256 context;
	uint8_t *buffer;
	int fd;
	ssize_t got;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;
	buffer = malloc(COPY_BUFFER);
	if (buffer == NULL) {
		close(fd);
		return false;
	}

	sha256_init(&context);
	while ((got = read(fd, buffer, COPY_BUFFER)) > 0)
		sha256_update(&context, buffer, (size_t)got);
	free(buffer);
	close(fd);
	if (got < 0)
		return false;
	sha256_final(&context, hex);
	return true;
}

/* ------------------------------------------------------------ loop devices */

/* Attaches file to a free loop device, read-only, and returns its path in a
 * caller-supplied buffer.
 *
 * LOOP_CTL_GET_FREE both allocates the device and creates its node, because
 * devtmpfs adds the node as part of device registration rather than through a
 * uevent this initramfs has nothing to listen for - but the retry below costs
 * nothing and covers a kernel that ever changes its mind about that. */
static bool loop_attach(const char *file, char *device, size_t size)
{
	struct loop_config config;
	int control, number, file_fd, loop_fd;
	int attempt;

	control = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
	if (control < 0) {
		msg("no /dev/loop-control: %s", strerror(errno));
		return false;
	}
	number = ioctl(control, LOOP_CTL_GET_FREE);
	close(control);
	if (number < 0) {
		msg("no free loop device: %s", strerror(errno));
		return false;
	}
	snprintf(device, size, "/dev/loop%d", number);

	for (attempt = 0; attempt < 100 && !path_exists(device); attempt++)
		sleep_ms(10);

	/* The backing file is opened read-only, which is what makes the loop
	 * device read-only however the flags below are read; the device itself
	 * still has to be opened for writing for LOOP_CONFIGURE to take it. */
	file_fd = open(file, O_RDONLY | O_CLOEXEC);
	if (file_fd < 0) {
		msg("cannot open %s: %s", file, strerror(errno));
		return false;
	}
	loop_fd = open(device, O_RDWR | O_CLOEXEC);
	if (loop_fd < 0) {
		msg("cannot open %s: %s", device, strerror(errno));
		close(file_fd);
		return false;
	}

	memset(&config, 0, sizeof(config));
	config.fd = (uint32_t)file_fd;
	config.info.lo_flags = LO_FLAGS_READ_ONLY;
	if (ioctl(loop_fd, LOOP_CONFIGURE, &config) != 0) {
		msg("cannot attach %s to %s: %s", file, device,
		    strerror(errno));
		close(loop_fd);
		close(file_fd);
		return false;
	}

	close(loop_fd);
	close(file_fd);
	return true;
}

/* ------------------------------------------------------------ block devices */

struct block_device {
	char name[DEVICE_NAME_MAX];
	bool removable;
	bool optical;
};

#define MAX_DEVICES 128

static struct block_device devices[MAX_DEVICES];
static int device_count;

static bool sysfs_flag(const char *name, const char *attribute)
{
	char path[PATH_MAX];
	char value[32];

	snprintf(path, sizeof(path), SYS_BLOCK "/%s/%s", name, attribute);
	if (!read_small_file(path, value, sizeof(value))) {
		/* A partition carries neither "removable" nor "size" of its
		 * own for this purpose; the disk it belongs to does. */
		snprintf(path, sizeof(path), SYS_BLOCK "/%s/../%s", name,
			 attribute);
		if (!read_small_file(path, value, sizeof(value)))
			return false;
	}
	return strcmp(value, "0") != 0;
}

static bool interesting_device(const char *name)
{
	static const char *const ignored[] = {
		"loop", "ram", "zram", "dm-", "md", "nbd", "fd", NULL,
	};
	char path[PATH_MAX];
	char size[32];
	int index;

	for (index = 0; ignored[index] != NULL; index++)
		if (strncmp(name, ignored[index], strlen(ignored[index])) == 0)
			return false;

	/* An empty optical drive is a block device of zero sectors, and so is
	 * a card reader with no card in it. Mounting either only produces an
	 * error to print. */
	snprintf(path, sizeof(path), SYS_BLOCK "/%s/size", name);
	if (!read_small_file(path, size, sizeof(size)))
		return false;
	return strcmp(size, "0") != 0;
}

static int compare_devices(const void *left, const void *right)
{
	const struct block_device *a = left;
	const struct block_device *b = right;

	/* Removable media first. The medium this kernel booted from is far
	 * more likely to be the USB stick or the disc in the drive than a
	 * filesystem on an internal disk that happens to look like one. */
	if (a->removable != b->removable)
		return a->removable ? -1 : 1;
	return strcmp(a->name, b->name);
}

static void scan_block_devices(void)
{
	DIR *dir;
	struct dirent *entry;

	device_count = 0;
	dir = opendir(SYS_BLOCK);
	if (dir == NULL)
		return;
	while ((entry = readdir(dir)) != NULL && device_count < MAX_DEVICES) {
		if (entry->d_name[0] == '.')
			continue;
		if (strlen(entry->d_name) >= DEVICE_NAME_MAX)
			continue;
		if (!interesting_device(entry->d_name))
			continue;
		strcpy(devices[device_count].name, entry->d_name);
		devices[device_count].removable =
			sysfs_flag(entry->d_name, "removable");
		devices[device_count].optical =
			strncmp(entry->d_name, "sr", 2) == 0 ||
			strncmp(entry->d_name, "scd", 3) == 0;
		device_count++;
	}
	closedir(dir);
	qsort(devices, (size_t)device_count, sizeof(devices[0]),
	      compare_devices);
}

/* --------------------------------------------------------- finding the medium */

/* The filesystems a Sowa medium can be, and how to mount one without changing
 * it. iso9660 is the ISO itself, whether it was burned or written to a stick
 * with dd; the other two are what someone who unpacked the ISO onto a
 * partition ends up with.
 *
 * Finding the medium means mounting every block device in the machine in turn,
 * including ones that have nothing to do with this boot, so "read-only" has to
 * mean it. MS_RDONLY alone does not for ext4: a filesystem with a dirty
 * journal is recovered at mount time, and the kernel enables write access to
 * do it even when the mount was asked for read-only. "noload" is what declines
 * that. The probe would otherwise write to the internal disk of a machine
 * someone booted a live medium on precisely because they did not want to
 * touch it. */
struct probe_filesystem {
	const char *name;
	const char *options;
};

static const struct probe_filesystem medium_filesystems[] = {
	{ "iso9660", NULL },
	{ "vfat", NULL },
	{ "ext4", "noload" },
	{ NULL, NULL },
};

struct medium {
	char device[DEVICE_PATH_MAX];   /* /dev/sr0 */
	char filesystem[16];
	bool optical;
};

/* Whether there is anything behind a device node at all.
 *
 * An optical drive with no disc in it is a block device like any other until
 * something tries to read it, and mounting it fails with ENOMEDIUM after the
 * kernel has printed "Can't open blockdev" - twice per filesystem tried, on
 * every pass of the retry loop, which buries the message that matters under
 * the one that does not. Opening it first is the same question asked quietly.
 * Card readers with no card in them answer the same way. */
static bool device_openable(const char *node)
{
	int fd = open(node, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		return false;
	close(fd);
	return true;
}

static bool try_mount(const char *device, const char *mountpoint,
		      const char **used_filesystem)
{
	int index;

	if (!device_openable(device))
		return false;

	for (index = 0; medium_filesystems[index].name != NULL; index++) {
		if (mount(device, mountpoint, medium_filesystems[index].name,
			  MS_RDONLY,
			  medium_filesystems[index].options) == 0) {
			if (used_filesystem != NULL)
				*used_filesystem =
					medium_filesystems[index].name;
			return true;
		}
	}
	return false;
}

/* What proves a mounted filesystem is the medium this kernel came from: the
 * marker file named after the payload's SHA-256. Without sowa.id= there is
 * nothing to be sure with, and the squashfs itself is accepted instead. */
static bool medium_matches(const char *mountpoint, const char *basedir,
			   const char *id)
{
	char path[PATH_MAX];

	if (id != NULL && id[0] != '\0') {
		snprintf(path, sizeof(path), "%s/%s/%s.id", mountpoint,
			 basedir, id);
		return path_exists(path);
	}
	snprintf(path, sizeof(path), "%s/%s/" LIVE_ARCH "/" SFS_NAME,
		 mountpoint, basedir);
	return path_exists(path);
}

static bool find_medium(const char *basedir, const char *id,
			struct medium *found)
{
	const char *filesystem;
	char node[DEVICE_PATH_MAX];
	int index;

	scan_block_devices();
	for (index = 0; index < device_count; index++) {
		snprintf(node, sizeof(node), "/dev/%.*s", DEVICE_NAME_MAX - 1,
			 devices[index].name);
		if (!device_openable(node)) {
			note_examined("  %-12s nothing in the drive\n", node);
			continue;
		}
		if (!try_mount(node, MEDIUM_MNT, &filesystem)) {
			note_examined("  %-12s no filesystem this can read\n",
				      node);
			continue;
		}
		if (medium_matches(MEDIUM_MNT, basedir, id)) {
			strcpy(found->device, node);
			snprintf(found->filesystem, sizeof(found->filesystem),
				 "%s", filesystem);
			found->optical = devices[index].optical;
			return true;
		}
		note_examined("  %-12s %s, but not this medium\n", node,
			      filesystem);
		umount(MEDIUM_MNT);
	}
	return false;
}

/* img_loop=: the ISO is a file on some filesystem rather than a medium of its
 * own, which is how GRUB's loopback.cfg boots it. The file is looked for on
 * every block device rather than resolved from img_dev=UUID=..., because
 * searching needs no filesystem UUID parsing and finds the image whichever
 * partition it was left on. */
static bool find_loop_image(const char *image, const char *restrict_device,
			    const char *basedir, const char *id,
			    struct medium *found)
{
	/* Same probe, same reason for "noload" - and the more likely case for
	 * it, since an ISO kept as a file lives on an ordinary disk that the
	 * machine may not have shut down cleanly. */
	static const struct probe_filesystem image_filesystems[] = {
		{ "ext4", "noload" },
		{ "vfat", NULL },
		{ "iso9660", NULL },
		{ NULL, NULL },
	};
	char node[DEVICE_PATH_MAX];
	char path[PATH_MAX];
	char loop[DEVICE_PATH_MAX];
	int index, filesystem;

	scan_block_devices();
	for (index = 0; index < device_count; index++) {
		snprintf(node, sizeof(node), "/dev/%.*s", DEVICE_NAME_MAX - 1,
			 devices[index].name);
		if (restrict_device != NULL && strcmp(node, restrict_device) != 0)
			continue;
		if (!device_openable(node))
			continue;

		for (filesystem = 0;
		     image_filesystems[filesystem].name != NULL; filesystem++)
			if (mount(node, IMG_MNT,
				  image_filesystems[filesystem].name,
				  MS_RDONLY,
				  image_filesystems[filesystem].options) == 0)
				break;
		if (image_filesystems[filesystem].name == NULL)
			continue;

		snprintf(path, sizeof(path), "%s/%s", IMG_MNT,
			 image[0] == '/' ? image + 1 : image);
		if (!path_exists(path)) {
			umount(IMG_MNT);
			continue;
		}
		msg("found %s on %s", image, node);
		if (!loop_attach(path, loop, sizeof(loop))) {
			umount(IMG_MNT);
			continue;
		}
		if (mount(loop, MEDIUM_MNT, "iso9660", MS_RDONLY, NULL) != 0) {
			msg("%s is not an ISO image: %s", path,
			    strerror(errno));
			umount(IMG_MNT);
			continue;
		}
		if (!medium_matches(MEDIUM_MNT, basedir, id)) {
			msg("%s is not this Sowa image", path);
			umount(MEDIUM_MNT);
			umount(IMG_MNT);
			continue;
		}
		strcpy(found->device, loop);
		snprintf(found->filesystem, sizeof(found->filesystem),
			 "iso9660");
		/* The image is a file, so it is never the optical case that
		 * copytoram=auto declines. */
		found->optical = false;
		return true;
	}
	return false;
}

/* --------------------------------------------------------------- copytoram */

static unsigned long long mem_available_kib(void)
{
	FILE *stream;
	char line[256];
	unsigned long long value = 0;

	stream = fopen("/proc/meminfo", "re");
	if (stream == NULL)
		return 0;
	while (fgets(line, sizeof(line), stream) != NULL) {
		if (sscanf(line, "MemAvailable: %llu kB", &value) == 1)
			break;
		value = 0;
	}
	fclose(stream);
	return value;
}

/*
 * Copy the root filesystem into RAM only when the machine can spare it. The
 * old Sowa image made this decision unconditionally at build time, in favour
 * of RAM, and a machine with less than three times the tree booted into a root
 * filesystem missing an arbitrary tail of itself.
 *
 * Three conditions, all of which have to hold:
 *
 *   not optical   A disc is already being read by a drive nobody is going to
 *                 walk off with, so the copy buys only speed - and buys it at
 *                 the price of the memory the live system was booted to use.
 *                 A USB stick is the opposite case: copying it is what lets it
 *                 be unplugged.
 *   under 4 GiB   Past that the copy takes longer than the boot it saves.
 *   headroom      MemAvailable has to exceed the image plus 2 GiB, so that a
 *                 system that copies still has somewhere to work.
 *
 * On a large machine this gives RAM speed and a medium that can be removed; on
 * a small one it streams from the medium and boots anyway. Neither outcome is
 * a failure, which is the whole point of deciding at boot rather than at build.
 */
static bool decide_copy_to_ram(const char *setting, bool optical,
			       unsigned long long image_bytes)
{
	unsigned long long available_kib, needed_kib;

	if (strcmp(setting, "n") == 0 || strcmp(setting, "no") == 0)
		return false;
	if (strcmp(setting, "y") == 0 || strcmp(setting, "yes") == 0 ||
	    setting[0] == '\0')
		return true;
	if (strcmp(setting, "auto") != 0) {
		msg("copytoram=%s is not understood; treating it as auto",
		    setting);
	}

	if (optical) {
		msg("copytoram: streaming from the optical drive");
		return false;
	}
	if (image_bytes >= COPYTORAM_MAX_BYTES) {
		msg("copytoram: the image is too large to copy (%llu MiB)",
		    image_bytes / (1024 * 1024));
		return false;
	}
	available_kib = mem_available_kib();
	needed_kib = image_bytes / 1024 + COPYTORAM_HEADROOM_KIB;
	if (available_kib < needed_kib) {
		msg("copytoram: %llu MiB available, %llu MiB needed; streaming from the medium",
		    available_kib / 1024, needed_kib / 1024);
		return false;
	}
	msg("copytoram: %llu MiB available; copying the %llu MiB image to RAM",
	    available_kib / 1024, image_bytes / (1024 * 1024));
	return true;
}

static bool copy_file(const char *from, const char *to)
{
	char *buffer;
	int in, out;
	ssize_t got;
	bool ok = true;

	in = open(from, O_RDONLY | O_CLOEXEC);
	if (in < 0) {
		msg("cannot read %s: %s", from, strerror(errno));
		return false;
	}
	out = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
	if (out < 0) {
		msg("cannot write %s: %s", to, strerror(errno));
		close(in);
		return false;
	}
	buffer = malloc(COPY_BUFFER);
	if (buffer == NULL) {
		close(in);
		close(out);
		return false;
	}

	while ((got = read(in, buffer, COPY_BUFFER)) > 0) {
		ssize_t written = 0;

		while (written < got) {
			ssize_t step = write(out, buffer + written,
					     (size_t)(got - written));

			if (step <= 0) {
				msg("cannot write %s: %s", to,
				    strerror(errno));
				ok = false;
				break;
			}
			written += step;
		}
		if (!ok)
			break;
	}
	if (got < 0) {
		msg("cannot read %s: %s", from, strerror(errno));
		ok = false;
	}

	free(buffer);
	close(in);
	if (close(out) != 0 && ok) {
		msg("cannot write %s: %s", to, strerror(errno));
		ok = false;
	}
	return ok;
}

/* ------------------------------------------------------------- switch_root */

/* Deletes the initramfs so its pages are freed before the live system starts.
 * The device check is the safety rail: everything that matters by this point -
 * /new_root and the mounts already moved under it - lives on a different
 * filesystem, so it is skipped rather than recursed into. */
static void remove_ramfs(int directory_fd, dev_t root_device)
{
	DIR *dir;
	struct dirent *entry;

	dir = fdopendir(directory_fd);
	if (dir == NULL) {
		close(directory_fd);
		return;
	}
	while ((entry = readdir(dir)) != NULL) {
		struct stat info;
		int flags = 0;

		if (strcmp(entry->d_name, ".") == 0 ||
		    strcmp(entry->d_name, "..") == 0)
			continue;
		if (fstatat(dirfd(dir), entry->d_name, &info,
			    AT_SYMLINK_NOFOLLOW) != 0)
			continue;
		if (info.st_dev != root_device)
			continue;
		if (S_ISDIR(info.st_mode)) {
			int child = openat(dirfd(dir), entry->d_name,
					   O_RDONLY | O_DIRECTORY | O_NOFOLLOW);

			if (child >= 0)
				remove_ramfs(child, root_device);
			flags = AT_REMOVEDIR;
		}
		unlinkat(dirfd(dir), entry->d_name, flags);
	}
	closedir(dir);
}

static void relocate_mount(const char *from, const char *to)
{
	if (mount(from, to, NULL, MS_MOVE, NULL) != 0)
		fatal("cannot move %s to %s: %s", from, to, strerror(errno));
}

static void switch_root(char **argv)
{
	struct stat root_info;
	int root_fd, console;
	char *init_argv[MAX_ARGS + 1];
	int index;

	/* The live system inherits these rather than mounting them again: it
	 * keeps the loop device and the squashfs under /run/sowa alive, which
	 * is what the root filesystem is being read through, and it means
	 * /etc/rc.d/rc.sysinit finds /proc, /sys and /dev already there. */
	relocate_mount("/dev", NEW_ROOT "/dev");
	relocate_mount("/proc", NEW_ROOT "/proc");
	relocate_mount("/sys", NEW_ROOT "/sys");
	relocate_mount("/run", NEW_ROOT "/run");

	if (stat("/", &root_info) != 0)
		fatal("cannot stat the initramfs: %s", strerror(errno));
	root_fd = open("/", O_RDONLY | O_DIRECTORY);
	if (root_fd >= 0)
		remove_ramfs(root_fd, root_info.st_dev);

	if (chdir(NEW_ROOT) != 0)
		fatal("cannot enter %s: %s", NEW_ROOT, strerror(errno));
	if (mount(".", "/", NULL, MS_MOVE, NULL) != 0)
		fatal("cannot make the new root the root: %s",
		      strerror(errno));
	if (chroot(".") != 0)
		fatal("cannot chroot into the new root: %s", strerror(errno));
	if (chdir("/") != 0)
		fatal("cannot enter the new root: %s", strerror(errno));

	/* The console moved with /dev, and reopening it there is what makes
	 * init's own file descriptors belong to the filesystem it is running
	 * on rather than to a ramfs that no longer exists. */
	console = open("/dev/console", O_RDWR | O_NOCTTY);
	if (console >= 0) {
		dup2(console, 0);
		dup2(console, 1);
		dup2(console, 2);
		if (console > 2)
			close(console);
	}

	/* Whatever the kernel handed this program that neither it nor the
	 * kernel claimed - "single", most usefully - is init's to interpret. */
	init_argv[0] = (char *)"init";
	for (index = 1; argv[index] != NULL && index < MAX_ARGS; index++)
		init_argv[index] = argv[index];
	init_argv[index] = NULL;

	execv("/sbin/init", init_argv);
	fatal("cannot execute /sbin/init: %s", strerror(errno));
}

/* -------------------------------------------------------------------- main */

int main(int argc, char **argv)
{
	const char *basedir, *id, *copytoram, *cow_spacesize, *image;
	const char *restrict_device;
	struct medium medium;
	char sfs_path[PATH_MAX];
	char checksum_path[PATH_MAX];
	char loop_device[DEVICE_PATH_MAX];
	char overlay_options[PATH_MAX * 3];
	char cow_options[64];
	struct stat sfs_info;
	unsigned long long deadline, waited;
	int console;
	bool found = false;
	bool copied = false;

	(void)argc;

	/* Nothing has been mounted yet, so this initramfs has no /dev and the
	 * kernel could not give this program a console: the messages below
	 * only exist once devtmpfs is up and /dev/console has been reopened
	 * onto the standard descriptors. */
	mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mount("sysfs", "/sys", "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID, "mode=0755");

	console = open("/dev/console", O_RDWR | O_NOCTTY);
	if (console >= 0) {
		dup2(console, 0);
		dup2(console, 1);
		dup2(console, 2);
		if (console > 2)
			close(console);
	}
	setvbuf(stdout, NULL, _IONBF, 0);

	if (mount("tmpfs", "/run", "tmpfs", MS_NOSUID | MS_NODEV,
		  "mode=0755") != 0)
		fatal("cannot mount /run: %s", strerror(errno));
	mkdir_p(MEDIUM_MNT);
	mkdir_p(IMG_MNT);
	mkdir_p(SFS_MNT);
	mkdir_p(COW_MNT);

	cmdline_read();
	basedir = cmdline_get("sowa.basedir", DEFAULT_BASEDIR);
	id = cmdline_get("sowa.id", "");
	copytoram = cmdline_get("copytoram", "auto");
	cow_spacesize = cmdline_get("cow_spacesize", NULL);
	image = cmdline_get("img_loop", NULL);
	restrict_device = cmdline_get("img_dev", NULL);

	msg("Sowa live init " VERSION);

	/* A USB controller takes seconds to enumerate a stick, and sysfs shows
	 * nothing at all until it has, so the search is retried rather than
	 * run once against whatever happened to be ready. */
	deadline = strtoull(cmdline_get("rootdelay", ""), NULL, 10);
	if (deadline == 0)
		deadline = DEFAULT_ROOTDELAY;
	for (waited = 0; waited <= deadline * 2; waited++) {
		examined[0] = '\0';
		if (image != NULL)
			found = find_loop_image(image, restrict_device,
						basedir, id, &medium);
		else
			found = find_medium(basedir, id, &medium);
		if (found)
			break;
		if (waited == 4)
			msg("waiting for the medium to appear");
		sleep_ms(500);
	}
	if (!found) {
		if (id[0] != '\0')
			fatal("no medium carrying %s/%s.id was found in %llu seconds",
			      basedir, id, deadline);
		fatal("no medium carrying %s/" LIVE_ARCH "/" SFS_NAME
		      " was found in %llu seconds",
		      basedir, deadline);
	}
	msg("medium: %s (%s)", medium.device, medium.filesystem);

	snprintf(sfs_path, sizeof(sfs_path),
		 MEDIUM_MNT "/%s/" LIVE_ARCH "/" SFS_NAME, basedir);
	if (stat(sfs_path, &sfs_info) != 0)
		fatal("the medium has no %s/" LIVE_ARCH "/" SFS_NAME, basedir);

	if (decide_copy_to_ram(copytoram, medium.optical,
			       (unsigned long long)sfs_info.st_size)) {
		char ram_options[64];
		char ram_path[PATH_MAX];

		mkdir_p(RAM_MNT);
		/* Sized to the image and nothing more: this tmpfs holds one
		 * file that is never written to again, and any slack in it is
		 * memory the live system does not get. */
		snprintf(ram_options, sizeof(ram_options), "mode=0755,size=%llu",
			 (unsigned long long)sfs_info.st_size + 1024 * 1024);
		if (mount("tmpfs", RAM_MNT, "tmpfs", MS_NOSUID | MS_NODEV,
			  ram_options) != 0)
			fatal("cannot make room in RAM for the image: %s",
			      strerror(errno));
		snprintf(ram_path, sizeof(ram_path), RAM_MNT "/" SFS_NAME);
		if (!copy_file(sfs_path, ram_path))
			fatal("copying the image to RAM failed");
		snprintf(sfs_path, sizeof(sfs_path), "%s", ram_path);
		copied = true;
	}

	if (cmdline_enabled("checksum")) {
		char expected[128] = "";
		char actual[65];

		snprintf(checksum_path, sizeof(checksum_path),
			 MEDIUM_MNT "/%s/" LIVE_ARCH "/" SFS_NAME ".sha256",
			 basedir);
		if (!read_small_file(checksum_path, expected, sizeof(expected)))
			fatal("checksum=y, but the medium carries no %s",
			      SFS_NAME ".sha256");
		/* "<hex>  root.sfs", as sha256sum writes it. */
		expected[strcspn(expected, " \t\n")] = '\0';
		msg("verifying the image");
		if (!sha256_file(sfs_path, actual))
			fatal("the image could not be read for verification");
		if (strcmp(expected, actual) != 0)
			fatal("the image is corrupt: expected %s, got %s",
			      expected, actual);
		msg("checksum ok");
	}

	if (!loop_attach(sfs_path, loop_device, sizeof(loop_device)))
		fatal("the image could not be attached to a loop device");
	if (mount(loop_device, SFS_MNT, "squashfs", MS_RDONLY, NULL) != 0)
		fatal("%s is not a squashfs this kernel can mount: %s",
		      sfs_path, strerror(errno));

	/* With the image in RAM nothing reads the medium again, so let go of
	 * it: this is what makes the stick removable once the boot is done. */
	if (copied) {
		if (umount(MEDIUM_MNT) == 0)
			msg("the image is in RAM; the medium can be removed");
	}

	snprintf(cow_options, sizeof(cow_options), "mode=0755%s%s",
		 cow_spacesize != NULL ? ",size=" : "",
		 cow_spacesize != NULL ? cow_spacesize : "");
	if (mount("tmpfs", COW_MNT, "tmpfs", MS_NOSUID | MS_NODEV,
		  cow_options) != 0)
		fatal("cannot mount the writable layer: %s", strerror(errno));
	mkdir_p(COW_MNT "/upper");
	mkdir_p(COW_MNT "/work");
	mkdir_p(NEW_ROOT);

	/* The live root: everything on the medium, read-only, with every write
	 * landing in the tmpfs above it. Nothing is copied and nothing is
	 * unpacked, so this costs the size of what is written rather than the
	 * size of the tree. */
	snprintf(overlay_options, sizeof(overlay_options),
		 "lowerdir=" SFS_MNT ",upperdir=" COW_MNT
		 "/upper,workdir=" COW_MNT "/work");
	if (mount("sowa", NEW_ROOT, "overlay", 0, overlay_options) != 0)
		fatal("cannot mount the overlay root: %s", strerror(errno));

	if (!path_exists(NEW_ROOT "/sbin/init"))
		fatal("the image has no /sbin/init");

	switch_root(argv);
	return 1;
}
