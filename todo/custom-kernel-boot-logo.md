# Custom kernel boot logo

## Goal

Replace the traditional Tux image shown above the framebuffer console during
kernel boot with a Sowa-specific image while retaining the existing behavior of
showing one copy per online CPU.

Sowa already enables the required kernel features in
`config/kernel-x86_64.fragment`:

```text
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_LOGO=y
CONFIG_LOGO_LINUX_CLUT224=y
```

The selected image is compiled into the kernel from the upstream file:

```text
drivers/video/logo/logo_linux_clut224.ppm
```

Keeping that filename means the upstream kernel Kconfig and Makefile do not
need modification.

## Prepare the image

Add the tracked source asset as:

```text
assets/kernel-logo.ppm
```

Use an RGB PPM image with:

- no alpha channel;
- no more than 224 distinct colors;
- a black background where transparency would otherwise be expected;
- preferably the upstream logo's 80 by 80 pixel dimensions.

The kernel logo format has no alpha transparency. Every pixel in the image is
drawn, so an unflattened transparent PNG must not be converted directly.

One way to prepare the asset with ImageMagick is:

```sh
magick input.png \
    -resize 80x80 \
    -background black -gravity center -extent 80x80 \
    -alpha remove -alpha off -colors 224 \
    ppm:assets/kernel-logo.ppm
```

Check the resulting dimensions and color count:

```sh
magick identify -format '%wx%h, %k colors\n' assets/kernel-logo.ppm
```

The kernel build's `pnmtologo` utility also validates the palette and fails if
the image contains more than 224 colors.

## Install the asset into the kernel source

In `scripts/stages/image/kernel.sh`, immediately after obtaining `linux_source`,
copy the repository asset over the upstream image:

```sh
logo="${PROJECT_ROOT}/assets/kernel-logo.ppm"
[[ -f "${logo}" ]] || die "kernel logo is missing: ${logo}"
install -m 0644 "${logo}" \
    "${linux_source}/drivers/video/logo/logo_linux_clut224.ppm"
```

This intentionally modifies the extracted source under `work/sources` as a
deterministic part of every kernel build. Do not rely on manually replacing the
file under `work/sources`; that directory is build state, is not tracked, and
may be recreated.

## Invalidate cached builds

Extend `invalidate_stale_kernel()` in `scripts/build.sh` so that a change to any
of these inputs rebuilds the kernel:

- `config/kernel-x86_64.fragment`;
- `assets/kernel-logo.ppm`;
- `scripts/stages/image/kernel.sh`.

When one changes, remove both cached completion stamps, as the existing kernel
configuration invalidation does:

```text
work/stamps/image/kernel.done
work/stamps/image/11-initramfs.done
```

The second invalidation is necessary because the image stage copies the newly
built kernel into the root filesystem and packages it for live and installed
systems.

## Build and test

Build the kernel and images normally:

```sh
make image
make iso
```

The default QEMU targets are headless and discard the video console on which
the kernel draws the logo. Open a graphical display and use several virtual
CPUs to verify the repeated image:

```sh
SOWA_QEMU_DISPLAY=gtk SOWA_QEMU_CPUS=4 make run-iso
```

If the installed QEMU lacks the GTK backend, use another available graphical
backend or Sowa's VNC option.

Verify that:

1. The new image appears on the video console.
2. One copy is drawn per online CPU.
3. Serial-console boot remains unaffected.
4. `logo.nologo` on the kernel command line still suppresses all copies.
5. The rebuilt live ISO and installed-system kernel both contain the change.

## Limitations

- The kernel framebuffer-logo mechanism repeats the selected logo once per
  online CPU. Replacing the image does not change that behavior.
- `logo.nologo` disables every copy; it does not limit the display to one.
- Showing exactly one logo, positioning it freely, adding animation, or using
  alpha transparency would require a kernel framebuffer-logo code change or a
  userspace boot-splash implementation instead.
