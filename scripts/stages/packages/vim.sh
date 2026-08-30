#!/usr/bin/env bash

set -Eeuo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "$0")/../../lib/common.sh"

vim_source="$(prepare_source vim)"
build_tree="${BUILD_DIR}/vim"
reset_build_dir "${build_tree}"
cp -a "${vim_source}/." "${build_tree}/"
pkgdir="$(pkg_stage vim)"

build_triplet="$(gcc -dumpmachine)"
target_configure_env
export LIBS=-ltinfow
export PKG_CONFIG=pkg-config
export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib64/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
cd "${build_tree}"
vim_cv_getcwd_broken=no \
vim_cv_memmove_handles_overlap=yes \
vim_cv_stat_ignores_slash=no \
vim_cv_terminfo=yes \
vim_cv_toupper_broken=no \
vim_cv_tgetent=zero \
vim_cv_tty_group=world \
vim_cv_tty_mode=0620 \
./configure \
    --prefix=/usr \
    --build="${build_triplet}" \
    --host="${TARGET}" \
    --with-features=huge \
    --with-tlib=ncursesw \
    --without-x \
    --without-wayland \
    --without-local-dir \
    --disable-gui \
    --disable-nls \
    --disable-acl \
    --disable-selinux \
    --disable-smack \
    --disable-xattr \
    --disable-libsodium \
    --enable-gpm=no \
    --enable-multibyte \
    --enable-terminal \
    --with-compiledby=Sowa
make -j"${JOBS}"
make DESTDIR="${pkgdir}" install

"${TARGET}-strip" "${pkgdir}/usr/bin/vim"
ln -sfn vim "${pkgdir}/usr/bin/vi"
[[ -x "${pkgdir}/usr/bin/vim" ]] || die "Vim was not installed"
[[ -L "${pkgdir}/usr/bin/vi" ]] || die "Vim did not install its vi link"
[[ -f "${pkgdir}/usr/share/vim/vim92/syntax/syntax.vim" ]] \
    || die "Vim runtime syntax files were not installed"
"${TARGET}-readelf" -d "${pkgdir}/usr/bin/vim" | grep -q 'libtinfow.so.6'
pkg_merge vim
log "installed Vim $(source_version vim)"
