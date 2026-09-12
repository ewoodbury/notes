# HDD Before Dataset

This is the complete pre-upgrade dataset for the GPT-5.6 Luna SSD replacement session. It was captured on 2026-09-07 at approximately 21:37 PDT on an HP Pavilion 15-cc6xx running CachyOS Linux.

## Hardware and Software State

| Component | Before state |
|---|---|
| CPU | Intel Core i7-8550U, 4 cores / 8 threads, 1.8 GHz base, up to 4.0 GHz |
| RAM | 12,124,348 KiB total; 4,655,136 KiB available |
| Kernel | `6.18.48-1-cachyos-lts` |
| Storage | Seagate ST1000LM035-1RK172, serial `ZDE4QF5Y`, 5400 RPM SMR SATA HDD |
| Device | `/dev/sda2`, Btrfs, approximately 15 GiB used of 928 GiB |
| Scheduler | `bfq`; read-ahead 8192 KiB; rotational flag 1 |
| Mount | `noatime,compress=zstd:3,discard=async,space_cache=v2` |
| Swap | 11.6 GiB zram, zstd; approximately 6.1 GiB compressed data / 6.5 GiB used |
| Power | `balanced` profile; CPU governor `powersave` |
| Thermal snapshot | Approximately 38-52 C across relevant thermal zones |

`/tmp` was tmpfs, so all disk tests used `/home/ethan/ssd-baseline-temp`. The test file was 512 MiB of incompressible data generated from `/dev/urandom`. Direct I/O was used for the principal throughput tests.

## Storage and Filesystem Results

| Workload | Result | Method |
|---|---:|---|
| Direct sequential write, 512 MiB | 69.5 MB/s | `dd`, 1 MiB blocks, direct, fsync |
| Direct sequential read, 512 MiB | 127 MB/s | `dd`, 1 MiB blocks, direct |
| Direct 4 KiB sequential read | 59.7 MB/s | `dd`, 4 KiB blocks, direct |
| 4 KiB random shell proxy | 96.96 ops/s, 10.313 ms/op | 1,000 random direct `dd` requests; includes process overhead |
| Create 1,000 empty files | 0.093 s | Warm-cache shell loop |
| Stat 1,000 files | 0.020 s | Warm-cache shell loop |
| Remove 1,000 files | 0.035 s | Warm-cache shell loop |

The improved tool-assisted run produced:

| Workload | Result | Latency details |
|---|---:|---|
| `fio` sequential write, 1 MiB QD1 | 98.6 MiB/s | average 9.75 ms; p99 39.7 ms |
| `fio` sequential read, 1 MiB QD1 | 69.6 MiB/s | average 14.36 ms; p95 11.34 ms; p99 16.45 ms |
| `fio` random read, 4 KiB QD1 | 138 IOPS, 555 KiB/s | average 7.195 ms; p95 12.78 ms; p99 18.744 ms |
| `fio` random read, 4 KiB QD32 | 138 IOPS, 556 KiB/s | average 230.88 ms; p95 384 ms; p99 531 ms |
| `fio` random 70% read / 30% write, QD1 | 65 read + 29 write IOPS | read average 11.781 ms; write average 7.729 ms |
| `ioping` direct 4 KiB | 94 IOPS | min 0.7126 ms; average 10.6 ms; max 36.9 ms |

The QD32 sequential read run was 30.8 MiB/s with approximately 1.077 s average latency, but it was collected after random workloads and is retained as a worst-case observation rather than a clean sustained-sequential result.

## Boot and Application Proxies

```text
firmware 3.680 s + loader 4.739 s + kernel 1.033 s + initrd 3.773 s + userspace 18.308 s = 31.534 s
graphical.target reached after 16.424 s in userspace
```

Warm executable initialization proxies from `hyperfine --warmup 2 --runs 10`:

| Command | Mean | Standard deviation | Range |
|---|---:|---:|---:|
| `firefox --version` | 55.9 ms | 3.2 ms | 51.6-60.6 ms |
| `chromium --version` | 66.9 ms | 7.6 ms | 57.4-79.4 ms |
| `thunar --version` | 85.8 ms | 25.8 ms | 45.0-118.4 ms |
| `ghostty --version` | 78.0 ms | 13.4 ms | 63.5-94.8 ms |

These commands do not open real GUI windows and are warm executable-start proxies, not full cold-start usability tests.

## CPU Control and Limitations

Single-process `openssl speed -seconds 5 sha256` produced 275,948.43 kB/s at 8 KiB and 284,916.44 kB/s at 16 KiB. This is a CPU/package control metric, not a storage result.

Raw-device `hdparm` and SMART access were attempted but denied without root privileges. Existing machine notes reported a prior healthy SMART result with zero reallocated, pending, offline-uncorrectable, and CRC sectors. The baseline was captured under substantial zram use and elevated I/O pressure, so the post-upgrade run records those confounders for comparison.
