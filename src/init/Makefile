# sowa-init: init(8) and the commands that talk to it.
#
# Built by scripts/stages/packages/init.sh with the cross toolchain, and
# buildable on the host with a plain "make" for a syntax check or a quick read
# of the warnings.

VERSION ?= 0.1
DESTDIR ?=
SBINDIR ?= /sbin
BINDIR ?= /usr/bin
RCDIR ?= /etc/rc.d
MANDIR ?= /usr/share/man
COMPDIR ?= /usr/share/bash-completion/completions

CC ?= cc
CFLAGS ?= -O2 -std=c11 -Wall -Wextra
CPPFLAGS += -DVERSION='"$(VERSION)"' -D_FORTIFY_SOURCE=2
LDFLAGS += -Wl,-z,relro,-z,now

PROGRAMS = init telinit shutdown halt runlevel
SCRIPTS = service chkconfig
# Not in SCRIPTS because it does not belong in /sbin: it changes nothing, needs
# no privilege, and is read by whoever is asking why a boot took as long as it
# did. It reads what the helpers in "functions" record, which is why it ships
# with them rather than on its own.
BIN_SCRIPTS = sowa-boottime
RC_FILES = rc
INITD_FILES = functions
# The manual pages for all of the above, and the format the whole of it is
# configured by. They are mdoc(7), which is what mandoc - the image's man -
# parses natively.
MAN5 = man/inittab.5
MAN8 = man/init.8 man/telinit.8 man/shutdown.8 man/halt.8 man/runlevel.8 \
       man/service.8 man/chkconfig.8 man/sowa-boottime.8
# Completions for the commands anyone types by hand. init, poweroff and reboot
# are not here because they are other names for telinit and halt, and are
# installed as links to those files below.
COMPLETIONS = completions/service completions/chkconfig completions/telinit \
	      completions/shutdown completions/halt completions/sowa-boottime

.PHONY: all install clean

all: $(PROGRAMS)

init: init.o request.o
telinit: telinit.o request.o
shutdown: shutdown.o request.o
halt: halt.o request.o
runlevel: runlevel.o request.o

$(PROGRAMS):
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

init.o telinit.o shutdown.o halt.o runlevel.o request.o: initreq.h

install: all
	install -d -m 0755 $(DESTDIR)$(SBINDIR)
	install -m 0755 $(PROGRAMS) $(SCRIPTS) $(DESTDIR)$(SBINDIR)
	# halt, poweroff and reboot are the same program under three names.
	ln -sf halt $(DESTDIR)$(SBINDIR)/poweroff
	ln -sf halt $(DESTDIR)$(SBINDIR)/reboot
	install -d -m 0755 $(DESTDIR)$(BINDIR)
	install -m 0755 $(BIN_SCRIPTS) $(DESTDIR)$(BINDIR)
	install -d -m 0755 $(DESTDIR)$(RCDIR)/init.d
	install -m 0755 $(RC_FILES) $(DESTDIR)$(RCDIR)
	install -m 0644 $(INITD_FILES) $(DESTDIR)$(RCDIR)/init.d
	install -d -m 0755 $(DESTDIR)$(MANDIR)/man5 $(DESTDIR)$(MANDIR)/man8
	install -m 0644 $(MAN5) $(DESTDIR)$(MANDIR)/man5
	install -m 0644 $(MAN8) $(DESTDIR)$(MANDIR)/man8
	# One program under three names is one page under three names. Links
	# rather than copies, so that "man reboot" and "man halt" cannot drift.
	ln -sf halt.8 $(DESTDIR)$(MANDIR)/man8/poweroff.8
	ln -sf halt.8 $(DESTDIR)$(MANDIR)/man8/reboot.8
	install -d -m 0755 $(DESTDIR)$(COMPDIR)
	install -m 0644 $(COMPLETIONS) $(DESTDIR)$(COMPDIR)
	# The completion loader looks for a file named after the command, so
	# every name a command answers to needs one. Each of these files
	# registers all of its names, so whichever was typed finds the rest.
	ln -sf telinit $(DESTDIR)$(COMPDIR)/init
	ln -sf halt $(DESTDIR)$(COMPDIR)/poweroff
	ln -sf halt $(DESTDIR)$(COMPDIR)/reboot

clean:
	rm -f $(PROGRAMS) *.o
