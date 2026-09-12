# SSD Upgrade — "After" Benchmark (Timetec 512GB SSD) — run `glm-5.3`

> Same commands and methodology as [before-baseline.md](before-baseline.md).
> After: Timetec 35TT2280SATA-512GB (M.2 SATA), non-rotational, `mq-deadline`
> scheduler. Old HDD still installed as `sda` but **unmounted from everywhere** —
> zero participation in results. Same btrfs layout, same mount options plus the
> `ssd` flag now auto-set. Kernel unchanged (`6.18.48-1-cachyos-lts`).

Date: 2026-09-12 · OS: CachyOS · i7-8550U · 12GB RAM + 11.6G zram
Captured 7 minutes after reboot.

## Head-to-head (identical fio commands, direct I/O, /home)

| Metric | HDD (before) | SSD (after) | Change |
|---|---:|---:|---|
| Seq write 1M, 2G | 80.2 MiB/s | **248 MiB/s** | **3.1×** |
| Seq read 1M, 2G | 112 MiB/s | **307 MiB/s** | **2.7×** |
| 4K randread QD1 | 96 IOPS (388 KiB/s) | **4658 IOPS (18.2 MiB/s)** | **48×** |
| 4K randwrite QD1 | 102 IOPS (408 KiB/s) | **4629 IOPS (18.1 MiB/s)** | **45×** |
| Derived op latency (1/IOPS, mixed QD1) | ~10.3 ms/op | **~0.21 ms/op** | **~49×** |
| Variance (seq write IOPS min/max) | 4–132 (chaotic, SMR stalls) | 196–278 (stable) | consistent |

The 4K random numbers are the ones that govern "day to day feel" — and they
improved ~46-48×, far more than sequential. The before-run's pathological
variance (IOPS dipping to 4) is gone.

## Boot time (systemd-analyze)

| Stage | HDD | SSD |
|---|---:|---:|
| Userspace | 18.308 s | **10.901 s** |
| graphical.target | 16.424 s | **9.487 s** |
| Root device init | 10.715 s | **4.312 s** |
| Firmware | 3.680 s | 3.699 s (unchanged) |
| Loader (UEFI) | 4.739 s | **17.192 s ⚠** |
| Total | 31.534 s | 35.313 s |

⚠ The UEFI loader stage regressed to 17.2s — this is bootloader/firmware
territory, not disk (firmware+kernel+device phases all improved). Likely boot
menu timeout or firmware scan of the still-present HDD. Worth checking
bootloader timeout before drawing conclusions; disk-visible boot work
(userspace) nearly halved.

## App startup proxies (hyperfine, 2 warmups, 10 runs)

Before values from `ssd/README.md` (luna-5.6 run, on the loaded HDD system):
caveat: runs on different days/load states.

| Command | Before | After | Change |
|---|---:|---:|---|
| `firefox --version` | 55.9 ms | **30.7 ms** | 1.8× |
| `chromium --version` | 66.9 ms | **38.2 ms** | 1.8× |
| `thunar --version` | 85.8 ms | **31.1 ms** | 2.8× |
| `ghostty --version` | 78.0 ms | **42.7 ms** | 1.8× |

## System state at capture

- Swap (zram): **5 MiB used** vs 7.3 GiB before (before was after 21h uptime —
  direction is right, magnitude needs a long-session check)
- iowait still 35-47% at capture, but that's 7-min-post-boot background churn
  (vmstat snapshot in `system-state-after.txt`)
- Load 1.73 falling from boot

## ioping note (not comparable)

Before-run ioping (0.52 ms) was page-cache polluted (1.9k iops is impossible on
that HDD); after-run buffered ioping showed 2.56 ms avg on btrfs zstd reads.
Treat both as unreliable; the fio direct-I/O latency row above is the honest
latency comparison.

## SMART

Pending — new drive `sudo smartctl -H -A /dev/sdb` output to be appended to
`smartctl-after.txt`.

## Raw outputs (this directory)

`fio-quick-after.txt`, `ioping-after.txt`, `system-state-after.txt`,
`app-usability-after.txt`
