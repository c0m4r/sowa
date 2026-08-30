#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Docker, which is eight upstreams rather than one:
#
#   moby           the engine - dockerd - and docker-proxy beside it
#   docker/cli     the docker command people actually type
#   buildx         the extended image builder, a Docker CLI plugin
#   compose        the multi-container application client, also a CLI plugin
#   containerd     the daemon dockerd hands containers to, its shim, and ctr
#   runc           the OCI runtime containerd's shim calls to make a container
#   libseccomp     which runc filters syscalls with, linked in statically
#   tini           installed as docker-init, for "docker run --init"
#
# They are one package because they are one program in practice: dockerd will
# not run without a containerd, containerd will not run a container without a
# shim and a runtime, and the versions of all four are matched by whoever
# released the engine. Splitting them would produce four packages that may only
# ever be installed and upgraded together.
#
# Everything but runc and tini is Go. The engine, CLI, containerd and Buildx
# carry their dependencies in vendor, so they are built with the module proxy
# shut off: the build cannot reach the network for something the lock did not
# pin, and their static binaries have the build identity trimmed out. Compose
# stopped publishing vendored source, so its separately checksum-pinned official
# static Linux plugin is installed instead; compiling it would make "make
# docker" network-dependent. runc is the other exception: it needs cgo because
# the code that enters a container's namespaces is C, and it therefore links the
# target's glibc.

libseccomp_source="$(prepare_source libseccomp)"
runc_source="$(prepare_source runc)"
containerd_source="$(prepare_source containerd)"
moby_source="$(prepare_source docker)"
cli_source="$(prepare_source docker-cli)"
buildx_source="$(prepare_source buildx)"
tini_source="$(prepare_source tini)"

docker_version="$(source_version docker)"
cli_version="$(source_version docker-cli)"
buildx_version="$(source_version buildx)"
compose_version="$(source_version compose)"
containerd_version="$(source_version containerd)"
runc_version="$(source_version runc)"
tini_version="$(source_version tini)"
build_time="$(package_build_date)"

seccomp_build="${BUILD_DIR}/docker-libseccomp"
seccomp_root="${BUILD_DIR}/docker-libseccomp-root"
moby_tree="${BUILD_DIR}/docker-moby"
cli_tree="${BUILD_DIR}/docker-cli"
buildx_tree="${BUILD_DIR}/docker-buildx"
containerd_tree="${BUILD_DIR}/docker-containerd"
runc_tree="${BUILD_DIR}/docker-runc"
tini_tree="${BUILD_DIR}/docker-tini"
tools_tree="${BUILD_DIR}/docker-tools"
go_tmp="${BUILD_DIR}/docker-go-tmp"
for tree in "${seccomp_build}" "${seccomp_root}" "${moby_tree}" "${cli_tree}" "${buildx_tree}" \
    "${containerd_tree}" "${runc_tree}" "${tini_tree}" "${tools_tree}" "${go_tmp}"; do
    reset_build_dir "${tree}"
done
# Go writes nothing into a source tree, but the docker/cli build has to add a
# go.mod to one and the man page generators write their output beside their
# input, so each source is copied and built from the copy.
cp -a "${moby_source}/." "${moby_tree}/"
cp -a "${cli_source}/." "${cli_tree}/"
cp -a "${buildx_source}/." "${buildx_tree}/"
mkdir -p "${buildx_tree}/bin"
cp -a "${containerd_source}/." "${containerd_tree}/"
cp -a "${runc_source}/." "${runc_tree}/"
cp -a "${tini_source}/." "${tini_tree}/"
pkgdir="$(pkg_stage docker)"

# ---------------------------------------------------------------- libseccomp

# runc applies the seccomp profile the engine sends it, and libseccomp is what
# it compiles that profile into a BPF program with. A runc built without it
# refuses every container whose specification names a filter - which is every
# container Docker starts, since the default profile is not opt-in - so this is
# not an optional feature that could be left out to save a dependency.
#
# It is built here as a private static library rather than as a package of its
# own, the way nginx's PCRE2 is: runc is the only thing in Sowa that wants it,
# and an image that does not ship Docker has no business shipping a library for
# it either.
#
# GPERF is answered with a stub. libseccomp generates the perfect hash of its
# syscall table with gperf and ships the generated file in the release tarball,
# but its configure insists on the tool regardless. Pointing it at a script that
# fails loudly keeps gperf off the list of things a build host has to install,
# while still turning "the shipped file went stale" into an error that says so
# rather than an empty file that fails to compile three steps later.
gperf_stub="${seccomp_build}/gperf-stub"
cat > "${gperf_stub}" <<'STUB'
#!/bin/sh
echo "libseccomp tried to run gperf: its shipped syscalls.perf.c is stale" >&2
exit 1
STUB
chmod 0755 "${gperf_stub}"

target_configure_env
seccomp_triplet="$(sh "${libseccomp_source}/build-aux/config.guess")"
# libseccomp's diagnostic code records __FILE__.  Its out-of-tree build names
# the source with an absolute path, which is then carried through the static
# archive into runc; map the private work directory to a stable relative name
# before compiling so an otherwise reproducible package does not expose its
# build location.
seccomp_cflags="-g -O2 -fmacro-prefix-map=${WORK_DIR}=."
(
    cd "${seccomp_build}"
    GPERF="${gperf_stub}" CFLAGS="${seccomp_cflags}" "${libseccomp_source}/configure" \
        --prefix="${seccomp_root}" \
        --libdir="${seccomp_root}/lib" \
        --build="${seccomp_triplet}" \
        --host="${TARGET}" \
        --disable-shared \
        --enable-static \
        --disable-python
    make -j"${JOBS}"
    make install
)
[[ -f "${seccomp_root}/lib/libseccomp.a" ]] || die "the static libseccomp was not built"
[[ ! -e "${seccomp_root}/lib/libseccomp.so" ]] \
    || die "libseccomp was built shared; runc would link a library the image does not have"

# ----------------------------------------------------------------------- Go

go_cache="${BUILD_DIR}/go-cache"
mkdir -p "${go_cache}"
export GOCACHE="${go_cache}"
# Buildx is a sizeable Go graph. Keep compiler work files beside its cache,
# under the configured build directory, rather than assuming /tmp has several
# gigabytes free on every build host.
export TMPDIR="${go_tmp}"
export GOOS=linux
export GOARCH
export GOTOOLCHAIN=local
export GOPROXY=off
# Vendored builds, with the VCS stamping Go 1.26 does by default turned off for
# all of them. Every source here is an unpacked release tarball with no Git
# metadata of its own, but the build tree lives under the checkout - and in the
# container the checkout is a bind mount whose .git belongs to another user, so
# git exits 128 and the build fails on a repository none of these programs came
# from. The version and revision each binary reports are the ldflags below, and
# they are the complete deliberate build identity. GOFLAGS rather than a flag on
# each command because docker/cli's manual page generator runs its own go build.
export GOFLAGS="-mod=vendor -buildvcs=false"
export CGO_ENABLED=0

# The two Go programs that run here rather than on the target: go-md2man, which
# turns upstream's markdown manual pages into roff, and docker/cli's own manual
# page generator, which has to be executed because most of the pages are
# generated from the command tree rather than written. Both are built for the
# build machine, which is why the pair of variables is read back from go rather
# than assumed.
go_host_os="$(go env GOHOSTOS)"
go_host_arch="$(go env GOHOSTARCH)"

# ---------------------------------------------------------------- containerd

containerd_ldflags="-s -w -buildid="
containerd_ldflags+=" -X github.com/containerd/containerd/v2/version.Version=${containerd_version}"
containerd_ldflags+=" -X github.com/containerd/containerd/v2/version.Revision=v${containerd_version}"
containerd_ldflags+=" -X github.com/containerd/containerd/v2/version.Package=github.com/containerd/containerd/v2"
(
    cd "${containerd_tree}"
    for command in containerd containerd-shim-runc-v2 ctr; do
        go build -trimpath -ldflags "${containerd_ldflags}" \
            -o "${containerd_tree}/bin/${command}" "./cmd/${command}"
    done
)

# --------------------------------------------------------------- moby: the
# engine and the userland proxy. The build tags are upstream's own, from
# hack/make.sh: netgo and osusergo keep the resolver and the account lookups in
# Go rather than in a libc this binary is not linked to, static_build goes with
# them, and nri_no_wasm leaves out the WebAssembly runtime for the node resource
# interface - a plugin mechanism this package does not ship and which is most of
# the binary's size when it is compiled in.
moby_ldflags="-s -w -buildid="
moby_ldflags+=" -X github.com/moby/moby/v2/dockerversion.Version=${docker_version}"
moby_ldflags+=" -X github.com/moby/moby/v2/dockerversion.GitCommit=docker-v${docker_version}"
moby_ldflags+=" -X github.com/moby/moby/v2/dockerversion.BuildTime=${build_time}"
moby_ldflags+=" -X github.com/moby/moby/v2/dockerversion.PlatformName=${DISTRO_NAME}"
moby_ldflags+=" -X github.com/moby/moby/v2/dockerversion.ProductName=docker"
(
    cd "${moby_tree}"
    go build -trimpath -tags "netgo osusergo static_build nri_no_wasm" \
        -ldflags "${moby_ldflags}" -o "${moby_tree}/bin/dockerd" ./cmd/dockerd
    go build -trimpath -tags "netgo osusergo static_build" \
        -ldflags "${moby_ldflags}" -o "${moby_tree}/bin/docker-proxy" ./cmd/docker-proxy
)

# ------------------------------------------------------------- docker/cli
#
# The client's module file is called vendor.mod, so that "go mod vendor" can be
# run against a tree whose own vendor directory would otherwise be part of the
# module. Upstream copies it into place for the length of a build
# (scripts/with-go-mod.sh); the copy here is the same trick, done once, in the
# build tree rather than in the source.
cp "${cli_tree}/vendor.mod" "${cli_tree}/go.mod"
cp "${cli_tree}/vendor.sum" "${cli_tree}/go.sum"
cli_ldflags="-s -w -buildid="
cli_ldflags+=" -X github.com/docker/cli/cli/version.Version=${cli_version}"
cli_ldflags+=" -X github.com/docker/cli/cli/version.GitCommit=v${cli_version}"
cli_ldflags+=" -X github.com/docker/cli/cli/version.BuildTime=${build_time}"
cli_ldflags+=" -X github.com/docker/cli/cli/version.PlatformName=${DISTRO_NAME}"
(
    cd "${cli_tree}"
    # grpcnotrace is upstream's: the client imports gRPC but never dials one, and
    # the tag lets the linker drop the tracing package and what it pulls in.
    go build -trimpath -tags "grpcnotrace" -ldflags "${cli_ldflags}" \
        -o "${cli_tree}/bin/docker" ./cmd/docker
)

# ------------------------------------------------------------------- Buildx
#
# Buildx is not a replacement for the builder inside dockerd: it is the Docker
# CLI plugin that selects and talks to BuildKit builders, which is what makes
# "docker buildx build" available. Like the Docker client, it discovers the
# plugin by its filename under /usr/lib/docker/cli-plugins rather than through
# PATH.
buildx_ldflags="-s -w -buildid="
buildx_ldflags+=" -X github.com/docker/buildx/version.Version=v${buildx_version}"
buildx_ldflags+=" -X github.com/docker/buildx/version.Revision="
(
    cd "${buildx_tree}"
    go build -trimpath -ldflags "${buildx_ldflags}" \
        -o "${buildx_tree}/bin/docker-buildx" ./cmd/buildx
)

# ---------------------------------------------------------------------- runc
#
# The one component with C in it. libcontainer's nsenter is a constructor that
# runs before the Go runtime starts - it is what unshares the namespaces a
# container is made of - so runc cannot be built with cgo off, and it therefore
# links the target's glibc like every other compiled program here.
#
# The build tags are upstream's default minus libpathrs, which would need a Rust
# library this repository does not build; runc's own pure-Go path resolution is
# what it falls back to, and features_pathrslite.go in the tarball is that
# fallback. seccomp is kept, and is why libseccomp was built above.
runc_ldflags="-s -w -buildid= -X main.gitCommit=v${runc_version}"
(
    cd "${runc_tree}"
    export CGO_ENABLED=1
    export PKG_CONFIG_PATH="${seccomp_root}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${seccomp_root}/lib/pkgconfig"
    # -buildmode=pie, as upstream builds it: runc is the program a container
    # escape would attack first, and it costs a relocation at exec.
    go build -trimpath -buildmode=pie -tags "seccomp urfave_cli_no_docs" \
        -ldflags "${runc_ldflags}" -o "${runc_tree}/bin/runc" .
)

# ---------------------------------------------------------------------- tini
#
# docker-init, which "docker run --init" makes PID 1 inside the container so
# that a process which reaps no children does not leave the container full of
# zombies. Upstream builds it with cmake; that is one C file and two headers, so
# it is compiled here instead rather than adding cmake to the host requirements.
# The generated header is the only thing cmake was needed for - it carries the
# version - and -Werror is dropped: a 2019 program compiled by GCC 16 warns
# about things that were not warnings when it was written.
sed -e "s/@tini_VERSION_MAJOR@/${tini_version%%.*}/" \
    -e "s/@tini_VERSION_MINOR@/$(printf '%s' "${tini_version}" | cut -d. -f2)/" \
    -e "s/@tini_VERSION_PATCH@/${tini_version##*.}/" \
    -e 's/@tini_VERSION_GIT@//' \
    "${tini_tree}/src/tiniConfig.h.in" > "${tini_tree}/src/tiniConfig.h"
grep -q "define TINI_VERSION \"${tini_version}\"" "${tini_tree}/src/tiniConfig.h" \
    || die "the generated tiniConfig.h does not name tini ${tini_version}"
"${CC}" -std=gnu99 -Wall -Wextra -O2 -D_FORTIFY_SOURCE=2 -fstack-protector \
    --param=ssp-buffer-size=4 -Wformat \
    -Wl,-z,relro -Wl,-Bsymbolic-functions \
    -I"${tini_tree}/src" \
    -o "${tini_tree}/docker-init" "${tini_tree}/src/tini.c"

# ------------------------------------------------------------- manual pages
#
# Every one of these upstreams writes its manual pages in markdown and converts
# them with go-md2man, which docker/cli vendors - so the converter is built from
# the same pinned tarball as the pages, and nothing has to be installed on the
# build host for a package to arrive documented.
(
    cd "${cli_tree}"
    GOOS="${go_host_os}" GOARCH="${go_host_arch}" CGO_ENABLED=0 \
        go build -trimpath -o "${tools_tree}/go-md2man" \
        ./vendor/github.com/cpuguy83/go-md2man/v2
)
[[ -x "${tools_tree}/go-md2man" ]] || die "go-md2man was not built; no manual page could be converted"

# The client's pages are generated from its command tree rather than written, so
# the generator is compiled and run for the build machine. Everything else is a
# markdown file in the tarball.
(
    cd "${cli_tree}"
    GO_MD2MAN="${tools_tree}/go-md2man" \
        GOOS="${go_host_os}" GOARCH="${go_host_arch}" CGO_ENABLED=0 \
        ./scripts/docs/generate-man.sh
)
(
    cd "${runc_tree}/man"
    for page in ./*.8.md; do
        "${tools_tree}/go-md2man" -in "${page}" -out "${runc_tree}/man/$(basename "${page}" .md)"
    done
)
"${tools_tree}/go-md2man" -in "${moby_tree}/man/dockerd.8.md" \
    -out "${moby_tree}/man/dockerd.8"
"${tools_tree}/go-md2man" -in "${containerd_tree}/docs/man/containerd-config.8.md" \
    -out "${containerd_tree}/docs/man/containerd-config.8"
"${tools_tree}/go-md2man" -in "${containerd_tree}/docs/man/containerd-config.toml.5.md" \
    -out "${containerd_tree}/docs/man/containerd-config.toml.5"

# ------------------------------------------------------------------ install
#
# The clients go in /usr/bin and everything a container is made of goes in
# /usr/sbin: dockerd and containerd are daemons, docker-proxy and the shim are
# started by them, and runc is a program that only makes sense as root. The
# names matter as much as the directories - containerd looks its shim up as
# "containerd-shim-runc-v2" on PATH, the shim looks up "runc", and dockerd looks
# up "docker-proxy" and "docker-init" - and /etc/rc.d/init.d gives a service
# PATH=/bin:/sbin:/usr/bin:/usr/sbin, which is what makes both halves reachable.
install -D -m 0755 "${cli_tree}/bin/docker" "${pkgdir}/usr/bin/docker"
install -D -m 0755 "${containerd_tree}/bin/ctr" "${pkgdir}/usr/bin/ctr"
install -D -m 0755 "${tini_tree}/docker-init" "${pkgdir}/usr/bin/docker-init"
install -D -m 0755 "${buildx_tree}/bin/docker-buildx" \
    "${pkgdir}/usr/lib/docker/cli-plugins/docker-buildx"
# Compose's release source deliberately excludes its vendor tree. Its official
# release binary is static, target-specific and locked above, so taking this
# route preserves the package's offline build guarantee instead of letting Go
# resolve an unpinned dependency graph during every build.
compose_plugin="$(locked_download_path docker-compose-linux-amd64)"
install -D -m 0755 "${compose_plugin}" \
    "${pkgdir}/usr/lib/docker/cli-plugins/docker-compose"
install -D -m 0755 "${moby_tree}/bin/dockerd" "${pkgdir}/usr/sbin/dockerd"
install -D -m 0755 "${moby_tree}/bin/docker-proxy" "${pkgdir}/usr/sbin/docker-proxy"
install -D -m 0755 "${containerd_tree}/bin/containerd" "${pkgdir}/usr/sbin/containerd"
install -D -m 0755 "${containerd_tree}/bin/containerd-shim-runc-v2" \
    "${pkgdir}/usr/sbin/containerd-shim-runc-v2"
install -D -m 0755 "${runc_tree}/bin/runc" "${pkgdir}/usr/sbin/runc"
"${TARGET}-strip" "${pkgdir}/usr/bin/docker-init" "${pkgdir}/usr/sbin/runc"

# The service. Docker is not in the image, so the root filesystem overlay -
# where every other init script in Sowa comes from - cannot carry this one: a
# path the image already has is a conflict an optional package is refused for.
# It is Sowa's own source, like src/init and the nginx and HAProxy scripts;
# what upstream ships is a systemd unit.
#
# The init script itself arrives switched off, with no runlevel links hidden in
# the package. config/hooks/docker.hooks enables and starts it after a first
# install; keeping that policy in the hooks makes it visible to sowa-pkg and
# leaves upgrades free to respect an administrator who later turns it off.
install -D -m 0755 "${PROJECT_ROOT}/src/docker/docker" \
    "${pkgdir}/etc/rc.d/init.d/docker"

# Where dockerd keeps its configuration and its data. Both are created by the
# daemon at startup if they are missing, and both are shipped so that the
# package owns them: a directory nothing owns is one nothing cleans up, and
# /var/lib/docker in particular has to be 0710 before the first container runs,
# not after.
install -d -m 0755 "${pkgdir}/etc/docker"
install -d -m 0710 "${pkgdir}/var/lib/docker"

# The completion comes out of the binary that is being packaged rather than from
# the copy in contrib, so it cannot describe a command set this docker does not
# have. It is the client's own "docker completion bash", which is why it is run
# here: the client is a static binary for the target, and the target's
# architecture is the build machine's - scripts/host-check.sh insists on it.
install -d -m 0755 "${pkgdir}/usr/share/bash-completion/completions"
"${cli_tree}/bin/docker" completion bash \
    > "${pkgdir}/usr/share/bash-completion/completions/docker"
chmod 0644 "${pkgdir}/usr/share/bash-completion/completions/docker"
bash -n "${pkgdir}/usr/share/bash-completion/completions/docker" \
    || die "the generated docker bash completion is not valid shell"

install -d -m 0755 "${pkgdir}/usr/share/man/man1" "${pkgdir}/usr/share/man/man5" \
    "${pkgdir}/usr/share/man/man8"
install -m 0644 "${cli_tree}"/man/man1/*.1 "${pkgdir}/usr/share/man/man1/"
install -m 0644 "${cli_tree}"/man/man5/*.5 "${pkgdir}/usr/share/man/man5/"
install -m 0644 "${moby_tree}/man/dockerd.8" "${pkgdir}/usr/share/man/man8/"
install -m 0644 "${runc_tree}"/man/*.8 "${pkgdir}/usr/share/man/man8/"
install -m 0644 "${containerd_tree}/docs/man/containerd-config.8" \
    "${pkgdir}/usr/share/man/man8/"
install -m 0644 "${containerd_tree}/docs/man/containerd-config.toml.5" \
    "${pkgdir}/usr/share/man/man5/"

# ----------------------------------------------------------------- checking

for program in usr/bin/docker usr/bin/ctr usr/bin/docker-init \
    usr/lib/docker/cli-plugins/docker-buildx usr/lib/docker/cli-plugins/docker-compose \
    usr/sbin/dockerd \
    usr/sbin/docker-proxy usr/sbin/containerd usr/sbin/containerd-shim-runc-v2 \
    usr/sbin/runc; do
    [[ -x "${pkgdir}/${program}" ]] || die "/${program} was not installed"
    "${TARGET}-readelf" -h "${pkgdir}/${program}" \
        | grep -q 'Advanced Micro Devices X86-64' \
        || die "/${program} was not built for the target architecture"
    if grep -aq "${WORK_DIR}" "${pkgdir}/${program}"; then
        die "/${program} records the build directory"
    fi
done

# The Go halves carry their own runtime and are linked against nothing, which is
# what makes them installable on a machine whose glibc is older or newer than
# the one they were built beside. runc is the exception and says so.
for static_program in usr/bin/docker usr/bin/ctr \
    usr/lib/docker/cli-plugins/docker-buildx usr/lib/docker/cli-plugins/docker-compose \
    usr/sbin/dockerd \
    usr/sbin/docker-proxy usr/sbin/containerd usr/sbin/containerd-shim-runc-v2; do
    if "${TARGET}-readelf" -d "${pkgdir}/${static_program}" 2>/dev/null | grep -q 'NEEDED'; then
        die "/${static_program} is dynamically linked; it is meant to be static"
    fi
done
runc_dynamic="$("${TARGET}-readelf" -d "${pkgdir}/usr/sbin/runc")"
grep -q 'libc.so.6' <<< "${runc_dynamic}" \
    || die "runc is not linked against the target's C library"
if grep -q 'libseccomp' <<< "${runc_dynamic}"; then
    die "runc links libseccomp dynamically; the image has no such library"
fi
# That runc can apply a seccomp profile at all. Without the seccomp build tag it
# still builds, still runs, and refuses every container the engine sends it -
# which is every container - with "seccomp not supported in this build", so the
# absence of that message is the check.
if grep -aqF 'seccomp: config provided but seccomp not supported' \
    "${pkgdir}/usr/sbin/runc"; then
    die "runc was built without seccomp support; it would refuse every container Docker starts"
fi
grep -aqF 'libseccomp' "${pkgdir}/usr/sbin/runc" \
    || die "runc does not carry libseccomp; its seccomp support would be a stub"

# tini is C compiled by the cross compiler rather than Go, so it is checked the
# way every other compiled program here is.
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/docker-init" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "docker-init was not built with the cross compiler"

# The versions the binaries report. These are ldflags, which are easy to get
# wrong in a way nothing else notices: a client that says "unknown-version" is
# still a working client, and the first place it shows up is a bug report from
# somebody who cannot say what they are running. The three Go binaries here are
# static and built for this machine's architecture, so they can simply be asked.
"${cli_tree}/bin/docker" --version | grep -qF "${cli_version}" \
    || die "the docker client does not report version ${cli_version}"
"${moby_tree}/bin/dockerd" --version | grep -qF "${docker_version}" \
    || die "dockerd does not report version ${docker_version}"
"${containerd_tree}/bin/containerd" --version | grep -qF "${containerd_version}" \
    || die "containerd does not report version ${containerd_version}"
"${buildx_tree}/bin/docker-buildx" version | grep -qF "v${buildx_version}" \
    || die "Buildx does not report version ${buildx_version}"
# Compose is asked as the package's own copy rather than as the download the
# other four are asked as their build trees: a download is a file curl wrote,
# so it is 0644 and cannot be executed at all, and the copy that ships is the
# one whose version the assertion is about anyway.
"${pkgdir}/usr/lib/docker/cli-plugins/docker-compose" version \
    | grep -qF "v${compose_version}" \
    || die "Compose does not report version ${compose_version}"

[[ -x "${pkgdir}/etc/rc.d/init.d/docker" ]] \
    || die "the docker init script was not installed; the package could not start at boot"
# The pid file the init script signals for a stop is the one dockerd is told to
# write. They are set in two different places, so the pair is checked here
# rather than discovered as a stop that reports success and leaves the engine
# running.
grep -q '^pidfile=/run/docker.pid$' "${pkgdir}/etc/rc.d/init.d/docker" \
    || die "the docker init script does not name /run/docker.pid"
grep -q -- "--pidfile \"\${pidfile}\"" "${pkgdir}/etc/rc.d/init.d/docker" \
    || die "the docker init script does not tell dockerd which pid file to write"
[[ "$(stat -c '%a' "${pkgdir}/var/lib/docker")" == 710 ]] \
    || die "/var/lib/docker must not be world readable; it holds every image and volume"

# The manual pages, which are generated rather than shipped by any of these
# tarballs - so an upstream that stops writing one, or a converter that fails
# quietly, would otherwise produce a package that installs and answers "man
# docker" with nothing.
for page in man1/docker.1 man1/docker-run.1 man5/Dockerfile.5 man8/dockerd.8 \
    man8/runc.8 man8/containerd-config.8; do
    [[ -s "${pkgdir}/usr/share/man/${page}" ]] \
        || die "/usr/share/man/${page} is missing from the package"
done
man1_pages="$(find "${pkgdir}/usr/share/man/man1" -name 'docker*.1' -printf 'x' | wc -c)"
((man1_pages > 100)) \
    || die "only ${man1_pages} docker client manual pages were generated; the generator ran but produced almost nothing"

# docker is published to the repository and installed on demand; it is not part
# of the image, so its staged tree is never merged into the sysroot.
pkg_keep_staged docker
log "installed docker ${docker_version} (Buildx ${buildx_version}, Compose ${compose_version}, containerd ${containerd_version}, runc ${runc_version}) into the package staging tree"
