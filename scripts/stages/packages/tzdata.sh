#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

# The IANA time zone database: what /usr/share/zoneinfo is, and the only thing
# that makes a clock mean a time rather than a number.
#
# Without it every program in the image is permanently UTC. glibc reads TZ, and
# on a name like "Europe/Warsaw" it opens /usr/share/zoneinfo/Europe/Warsaw; if
# the file is not there it falls back to UTC and reports no error, so the
# failure is a wrong answer rather than a message. localtime(3), date(1),
# cron's idea of when a job is due and Python's zoneinfo module all go through
# it. chrony makes the mistake easier to miss: the clock is correct to the
# millisecond and still displayed in the wrong zone.
#
# Two tarballs, because IANA ships the data and the compiler separately. Only
# zic is built, and it is built for the machine doing the build rather than for
# the target: it runs here, and what it emits - TZif files, big-endian by
# specification - is the same on every architecture. So this stage cross-compiles
# nothing, and deliberately does not call target_configure_env.

require_command make
require_command gcc

tzcode_archive="$(locked_download_path tzcode)"
tzdata_archive="$(locked_download_path tzdata)"
version="$(source_version tzdata)"
build_tree="${BUILD_DIR}/tzdata"
reset_build_dir "${build_tree}"
pkgdir="$(pkg_stage tzdata)"

# Both tarballs are flat - no leading directory - and are meant to be unpacked
# over each other, which is why prepare_source is not used here.
validate_archive_members "${tzcode_archive}"
validate_archive_members "${tzdata_archive}"
tar -xf "${tzcode_archive}" -C "${build_tree}"
tar -xf "${tzdata_archive}" -C "${build_tree}"

make -C "${build_tree}" CC=gcc zic
[[ -x "${build_tree}/zic" ]] || die "tzcode ${version} did not build zic"

# The regions, plus the three files that are not regions: "etcetera" carries UTC
# and the Etc/GMT offsets, "backward" the old names that scripts and older
# systems still use (US/Eastern, Poland), and "factory" the placeholder zone for
# a machine nobody has configured yet.
zone_files=(
    africa antarctica asia australasia europe
    northamerica southamerica etcetera backward factory
)
for zone_file in "${zone_files[@]}"; do
    [[ -f "${build_tree}/${zone_file}" ]] \
        || die "tzdata ${version} is missing the ${zone_file} source file"
done

# "-b fat" writes both the 32-bit and 64-bit tables. Current tzcode defaults to
# slim, which glibc reads correctly, but fat is what every reader understands
# and the difference is about a megabyte and a half in an image that is already
# hundreds - a bad trade to make against a program that reads the file wrong.
install -d -m 0755 "${pkgdir}/usr/share/zoneinfo"
(cd "${build_tree}" && ./zic -b fat -d "${pkgdir}/usr/share/zoneinfo" "${zone_files[@]}")

# The tables tzselect(8) and anything offering a list of zones reads. They are
# data about the data, not compiled, and are installed alongside it.
for table in zone.tab zone1970.tab iso3166.tab; do
    [[ -f "${build_tree}/${table}" ]] || die "tzdata ${version} is missing ${table}"
    install -m 0644 "${build_tree}/${table}" "${pkgdir}/usr/share/zoneinfo/${table}"
done

# The system's own zone. UTC is the only defensible default for an image that
# does not know where it will boot; sowa-setup and the administrator change it
# by repointing this link at another file under zoneinfo.
install -d -m 0755 "${pkgdir}/etc"
ln -sfn ../usr/share/zoneinfo/UTC "${pkgdir}/etc/localtime"

# A zic that ran and produced nothing would leave a tree that looks installed.
# Check the two ends of the range: the default zone, and a compiled region file
# with the rules a plain offset would not have.
for zone in UTC Europe/Warsaw America/New_York Australia/Sydney; do
    [[ -f "${pkgdir}/usr/share/zoneinfo/${zone}" ]] \
        || die "tzdata ${version} did not compile the ${zone} zone"
    [[ "$(head -c 4 "${pkgdir}/usr/share/zoneinfo/${zone}")" == TZif ]] \
        || die "${zone} was written but is not a TZif file"
done
[[ -L "${pkgdir}/etc/localtime" ]] || die "/etc/localtime link was not installed"

zone_count="$(find "${pkgdir}/usr/share/zoneinfo" -type f ! -name '*.tab' | wc -l)"
((zone_count > 300)) || die "tzdata ${version} compiled only ${zone_count} zones"
pkg_merge tzdata
log "installed tzdata ${version}: ${zone_count} zones, /etc/localtime defaulting to UTC"
