#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# Sudo authenticates with the shadow passwords already managed by shadow and
# libxcrypt.  PAM, LDAP, SSSD, SELinux and AppArmor would either make it depend
# on services Sowa does not ship or permit configure to pick host facilities.
# The policy stays local in /etc/sudoers, with wheel as the explicit opt-in
# administrative group (the base account database already defines it).

sudo_source="$(prepare_source sudo)"
build_tree="${BUILD_DIR}/sudo"
reset_build_dir "${build_tree}"
# Built in a copy of the source rather than beside it. sudo's debug and warning
# macros quote __FILE__ and are compiled in unconditionally - they are how it
# reports where it refused something, not an assertion a release build drops -
# so an out-of-tree build spells every one of those paths absolutely and writes
# the builder's home directory into all eight objects, which is what
# pkg_merge's build-path check rejects.
cp -a "${sudo_source}/." "${build_tree}/"
pkgdir="$(pkg_stage sudo)"

# AC_CONFIG_AUX_DIR puts the helper scripts in scripts/ rather than at the top.
build_triplet="$(sh "${sudo_source}/scripts/config.guess")"
target_configure_env
cd "${build_tree}"
./configure \
    --prefix=/usr \
    --bindir=/usr/bin \
    --sbindir=/usr/sbin \
    --libdir=/usr/lib64 \
    --sysconfdir=/etc \
    --with-rundir=/run/sudo \
    --with-vardir=/var/lib/sudo \
    --with-sudoers-mode=0440 \
    --with-secure-path \
    --without-pam \
    --without-sendmail \
    --without-ldap \
    --without-sssd \
    --without-selinux \
    --without-apparmor \
    --disable-nls \
    --disable-log-server \
    --disable-log-client \
    --disable-rpath \
    --build="${build_triplet}" \
    --host="${TARGET}"
make -j"${JOBS}"
# Upstream's install rule forces chown(1) through install -o/-g.  Staging trees
# intentionally retain the build user's ownership (the package archive assigns
# numeric root ownership reproducibly), and unprivileged builds cannot chown,
# so suppress that host-side ownership operation.
make INSTALL_OWNER= DESTDIR="${pkgdir}" install

# The loadable policy modules live in libexec, not in the target's linker
# search path.  Their libtool archives are useful only while building sudo and
# would otherwise advertise host-side link dependencies to target builds.
rm -f "${pkgdir}"/usr/libexec/sudo/*.la

# The upstream sample leaves wheel disabled.  Sowa creates the wheel group in
# its base account database, so enabling this one rule makes administration an
# intentional group-membership decision rather than an undocumented edit to
# the policy file.  sudoers stays root-owned and unreadable by normal users.
sed -i 's|^# %wheel ALL=(ALL:ALL) ALL$|%wheel ALL=(ALL:ALL) ALL|' \
    "${pkgdir}/etc/sudoers"
grep -qx '%wheel ALL=(ALL:ALL) ALL' "${pkgdir}/etc/sudoers" \
    || die "sudoers does not grant wheel members administrative access"
[[ "$(stat -c '%a' "${pkgdir}/etc/sudoers")" == 440 ]] \
    || die "sudoers must be mode 0440"

# visudo is not in /usr/bin: it is an administrative command and sudo installs
# it under --sbindir, which is where the other packages here put theirs too.
for binary in sudo sudoedit cvtsudoers sudoreplay; do
    [[ -x "${pkgdir}/usr/bin/${binary}" ]] \
        || die "sudo did not install ${binary}"
done
[[ -x "${pkgdir}/usr/sbin/visudo" ]] || die "sudo did not install visudo"
[[ "$(stat -c '%a' "${pkgdir}/usr/bin/sudo")" == 4755 ]] \
    || die "sudo is not setuid root"
[[ -d "${pkgdir}/etc/sudoers.d" ]] \
    || die "sudo did not install the sudoers drop-in directory"
[[ -f "${pkgdir}/usr/libexec/sudo/sudoers.so" ]] \
    || die "sudo did not install its sudoers policy plugin"

while IFS= read -r binary; do
    mode="$(stat -c '%a' "${binary}")"
    "${TARGET}-strip" "${binary}"
    chmod "${mode}" "${binary}"
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" -type f -perm -u+x -print)
while IFS= read -r library; do
    "${TARGET}-strip" "${library}"
done < <(find "${pkgdir}/usr/libexec/sudo" -type f \
    \( -name '*.so' -o -name '*.so.*' \) -print)

"${TARGET}-readelf" -d "${pkgdir}/usr/bin/sudo" | grep -q 'libc.so.6'
"${TARGET}-readelf" -d "${pkgdir}/usr/libexec/sudo/sudoers.so" | grep -q 'libcrypt.so.2' \
    || die "sudoers does not link libxcrypt; it could not verify shadow passwords"
# sudo is the one package here that must carry a run-time library path. It
# loads its policy plugin and libsudo_util from /usr/libexec/sudo, which is not
# a directory the loader searches, so a sudo with no RUNPATH is a sudo that
# cannot start. The rule the other stages state as "no run-time path at all"
# therefore becomes "no run-time path this image did not intend": every element
# of every RUNPATH in the package has to be one of the two known ones, which is
# what catches a build-tree path without also failing on the plugin directory.
while IFS= read -r object; do
    run_paths="$("${TARGET}-readelf" -d "${object}" \
        | sed -n 's/.*R\(UN\)\?PATH.*\[\(.*\)\]/\2/p')"
    [[ -n "${run_paths}" ]] || continue
    while IFS= read -r element; do
        case "${element}" in
            /usr/libexec/sudo | /usr/lib64) ;;
            *) die "${object#"${pkgdir}"} carries the run-time library path ${element}" ;;
        esac
    done < <(tr ':' '\n' <<<"${run_paths}")
done < <(find "${pkgdir}/usr/bin" "${pkgdir}/usr/sbin" "${pkgdir}/usr/libexec/sudo" \
    -type f -print)
# And the half of that which is load-bearing, asserted rather than assumed: the
# plugin directory has to be on sudo's own path or it finds no policy at all.
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/sudo" | grep -q '/usr/libexec/sudo' \
    || die "sudo has no run-time path to /usr/libexec/sudo; it could not load its policy plugin"
cross_gcc_version="$("${CC}" -dumpfullversion)"
"${TARGET}-readelf" -p .comment "${pkgdir}/usr/bin/sudo" \
    | grep -q "GCC: (GNU) ${cross_gcc_version}" \
    || die "sudo was not built with the cross compiler"
leaked="$(grep -rlF "${PROJECT_ROOT}" "${pkgdir}" || true)"
[[ -z "${leaked}" ]] || die "sudo installed files containing the build path: ${leaked}"
pkg_merge sudo
log "installed sudo $(source_version sudo)"
