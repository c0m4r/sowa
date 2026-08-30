# Swap and zram

Sowa enables a zram swap device at boot. zram keeps compressed pages in memory,
giving the kernel somewhere to move cold pages without writing them to a disk.
This is especially useful on the live medium, where the writable overlay is a
tmpfs and may have no writable disk behind it.

## Defaults

The `zram` service reads `/etc/sowa/zram.conf`. Its shipped settings are:

| Setting | Default | Meaning |
| --- | --- | --- |
| `ZRAM_SIZE` | `50%` | maximum uncompressed data, as a share of RAM |
| `ZRAM_ALGORITHM` | `zstd` | compression algorithm |
| `ZRAM_PRIORITY` | `100` | swap priority |
| `ZRAM_SWAPPINESS` | `100` | kernel preference for using swap while active |

The size is a ceiling, not a reservation. An empty device consumes almost
nothing, and its real memory use is the compressed size of pages written to it.

The kernel builds zram and its zstd and LZO backends in rather than as modules.
The service records the previous swappiness value and restores it when stopped.

## Administration

```sh
service zram status
zramctl
free -m
```

Edit `/etc/sowa/zram.conf` and restart the service to apply changes:

```sh
service zram restart
```

Disable it for subsequent boots with:

```sh
chkconfig zram off
```

`rc.sysinit` also runs `swapon -a` for entries in `/etc/fstab`. Disk swap and
zram can coexist; the higher zram priority makes it fill before lower-priority
disk swap.

The recovery image benefits less from zram because its root is a ramfs, whose
pages cannot be swapped. Anonymous memory used by running programs can still be
compressed.

See `zram.conf(5)` and `/root/sowa-howto/zram.txt` on a running system.
