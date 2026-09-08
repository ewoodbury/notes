# SSD Replacement Baseline

This section records the pre-upgrade performance baseline for the HP Pavilion 15-cc6xx. The measurements were taken on 2026-09-07 at 21:37 PDT on branch `glm-5.3`, commit `65299c05c8ee6229c14a00b99cdb36df0caa0bc4` before these notes were added.

## Executive Summary

The current system disk is a Seagate ST1000LM035-1RK172 1 TB 5400 RPM SMR SATA HDD. It is the dominant expected storage bottleneck. The root and home filesystems are Btrfs on `/dev/sda2`; `/tmp` is tmpfs, so disk tests were deliberately run under `/home/ethan/ssd-baseline-temp` rather than `/tmp`.

The most useful comparison values are:

| Metric | HDD baseline | Measurement |
|---|---:|---|
| Direct sequential write, 512 MiB | 69.5 MB/s | `dd`, 1 MiB blocks, direct + fsync |
| Direct sequential read, 512 MiB | 127 MB/s | `dd`, 1 MiB blocks, direct |
| Direct 4 KiB sequential read | 59.7 MB/s | `dd`, 4 KiB blocks, direct |
| 4 KiB random probe | 97 ops/s, 10.3 ms/op | 1,000 random `dd` processes; low-fidelity latency proxy |
| Boot to graphical target | 16.424 s | `systemd-analyze` |
| Total boot | 31.534 s | firmware + loader + kernel + initrd + userspace |
| SHA-256, 8 KiB blocks | 275,948.43 kB/s | `openssl speed -seconds 5 sha256` |
| App executable initialization proxy | Firefox 1.034 s; Chromium 3.534 s; Thunar 0.674 s; Ghostty 0.554 s | `--version`, shell timing |

These values are a baseline, not a prediction of the replacement SSD. CPU, RAM, kernel, filesystem, packages, and power state should remain fixed where possible for a meaningful comparison.

## System Snapshot

| Component | Baseline detail |
|---|---|
| Laptop | HP Pavilion 15-cc6xx, hostname `cachyos` |
| OS | CachyOS Linux, rolling release |
| Kernel | `6.18.48-1-cachyos-lts` |
| CPU | Intel Core i7-8550U, 4 cores / 8 threads, 1.8 GHz base, up to 4.0 GHz |
| RAM | 12,124,348 KiB total; 4,655,136 KiB available at capture |
| Swap | 11.6 GiB zram, zstd, priority 100; 6.1 GiB data and 6.5 GiB used at capture |
| Storage | Seagate ST1000LM035-1RK172, serial `ZDE4QF5Y`, 5400 RPM, SATA/AHCI, rotational |
| Controller | Intel Sunrise Point-LP SATA controller, AHCI mode |
| Device scheduler | `bfq`; read-ahead 8192 KiB; rotational flag 1 |
| Filesystem | Btrfs, root subvolume `/@`, `noatime,compress=zstd:3,discard=async,space_cache=v2` |
| Root usage | 15 GiB used of 928 GiB; approximately 2% used |
| Power | `balanced` power profile; CPU governor reported `powersave` |
| Thermal snapshot | CPU/package-related thermal readings approximately 38-52 C |
| Kernel command line | Includes `libata.force=1.00:nolpm`, `intel_idle.max_cstate=3`, and `pcie_aspm=off` |

The existing Linux setup notes document that the laptop has one occupied 2.5-inch SATA bay and an empty M.2 2280 SATA-only slot. NVMe is not supported by this board according to those notes; verify the replacement drive interface before purchase.

## Measurements

### Storage throughput

All file tests used `/home/ethan/ssd-baseline-temp/random-data.bin`, a 512 MiB incompressible file generated from `/dev/urandom`. Direct I/O was used for the principal throughput measurements to avoid reporting page-cache speed.

```text
dd if=/dev/urandom of=.../random-data.bin bs=1M count=512 oflag=direct conv=fsync
536870912 bytes, 7.72522 s, 69.5 MB/s

dd if=.../random-data.bin of=/dev/null bs=1M iflag=direct
536870912 bytes, 4.21701 s, 127 MB/s

dd if=.../random-data.bin of=/dev/null bs=4K count=131072 iflag=direct
536870912 bytes, 8.99751 s, 59.7 MB/s
```

The 4 KiB random proxy selected 1,000 random blocks from the 512 MiB file and ran one direct 4 KiB `dd` process per request. Total elapsed time was 10.313 s, equivalent to 96.96 requests/s and 10.313 ms/request. This includes process startup and shell overhead and must not be treated as a proper disk IOPS or latency result. Install `fio` for the post-upgrade run if package installation is available.

The metadata probe created, tested, and removed 1,000 empty files under one directory. Timings were 0.093 s create, 0.020 s stat, and 0.035 s removal. These were warm-cache results and are only a rough filesystem reference.

`hdparm -Tt /dev/sda` and direct `smartctl -x /dev/sda` were attempted but denied because this session does not have root privileges. Existing system notes report a prior healthy SMART result with zero reallocated, pending, offline-uncorrectable, and CRC sectors, while also noting nonzero historical device-statistics error counters. Re-run SMART as root before removal if drive health documentation is required.

### Boot and system responsiveness proxies

`systemd-analyze` reported:

```text
firmware 3.680 s + loader 4.739 s + kernel 1.033 s + initrd 3.773 s + userspace 18.308 s = 31.534 s
graphical.target reached after 16.424 s in userspace
```

The critical chain included `dev-sda2.device` and `systemd-journal-flush.service` (2.178 s). The longest listed services included `plocate-updatedb.service` (36.126 s) and `man-db.service` (26.518 s); these are not necessarily on the graphical-target critical path and should be distinguished from storage latency in comparisons.

Executable initialization proxies were measured with shell `time` and each program's version command. They do not open a real GUI window and are not full cold-start UX measurements:

| Command | Elapsed |
|---|---:|
| `firefox --version` | 1.034 s |
| `chromium --version` | 3.534 s |
| `thunar --version` | 0.674 s |
| `ghostty --version` | 0.554 s |

### CPU reference

`openssl speed -seconds 5 sha256` produced these single-process SHA-256 throughput values:

| Block size | Throughput |
|---:|---:|
| 16 bytes | 20,734.60 kB/s |
| 64 bytes | 64,011.89 kB/s |
| 256 bytes | 156,630.84 kB/s |
| 1,024 bytes | 237,614.86 kB/s |
| 8,192 bytes | 275,948.43 kB/s |
| 16,384 bytes | 284,916.44 kB/s |

This is a CPU/package reference and should not materially change with an SSD. The `dd` zero-to-null result, 4,096 MiB in 0.384 s, is excluded as a useful memory metric because the kernel can optimize that path.

## Reproduction and Comparison Protocol

1. Reboot before the post-upgrade run and record the same kernel, power profile, thermal readings, memory availability, zram state, and load average.
2. Use the same filesystem mount options and the same 512 MiB incompressible test file size. Do not benchmark in `/tmp` because it is tmpfs on this machine.
3. Prefer `fio` for random I/O after the reinstall. Suggested profiles are 4 KiB random read, queue depth 1 and 32, plus 70/30 read/write mixed I/O. Record IOPS, average latency, p95, p99, and bandwidth.
4. Repeat direct sequential read/write tests at least three times and report median plus individual runs. The HDD values above are single runs, so they are suitable as a practical baseline but not a statistically robust sample.
5. Repeat `systemd-analyze`, application startup with fresh temporary profiles, and a representative project/file-open workload. The version-command timings above should be retained only as a simple executable-start proxy.
6. Preserve package versions, display session, compositor setting, kernel command line, and background services, or document every difference.
7. Remove the temporary 512 MiB file before drive replacement; it is not part of the repository.

## Limitations

- No root access was available for raw-device `hdparm` or SMART data.
- `fio`, `hyperfine`, `sysbench`, `ioping`, and `stress-ng` were not installed, so this baseline does not include high-quality queue-depth, latency-distribution, or standardized whole-system scores.
- Current zram usage was substantial, and system I/O pressure was high during inventory. This can affect application behavior and makes the baseline intentionally representative of the live system rather than a clean-room benchmark.
- A replacement OS installation can change package versions, services, filesystem layout, swap configuration, and bootloader behavior. Those changes must be recorded separately from the storage-device effect.
