# sowa-liveinit: the /init of the live medium's initramfs.
#
# Built by scripts/stages/image/11-initramfs.sh with the cross toolchain, and
# buildable on the host with a plain "make" for a syntax check or a read of the
# warnings.
#
# Static, because this is the only program in the initramfs: linking it against
# the shared glibc would mean shipping the dynamic loader and the C library
# beside it, which is most of the reason a shell-based early userspace costs
# twenty megabytes and this one costs one.

VERSION ?= 0.1
LIVE_ARCH ?= x86_64
DESTDIR ?=
BINDIR ?= /

CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra
CPPFLAGS += -DVERSION='"$(VERSION)"' -DLIVE_ARCH='"$(LIVE_ARCH)"' \
	-D_FORTIFY_SOURCE=2
LDFLAGS += -static

PROGRAM = liveinit

.PHONY: all install clean

all: $(PROGRAM)

$(PROGRAM): liveinit.o
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

install: all
	install -d -m 0755 $(DESTDIR)$(BINDIR)
	# The kernel runs /init out of the initramfs, and this is it.
	install -m 0755 $(PROGRAM) $(DESTDIR)$(BINDIR)/init

clean:
	rm -f $(PROGRAM) *.o
