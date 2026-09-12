# GPT-5.6 Luna SSD Benchmark Session

This folder is the self-contained record for the SSD replacement benchmark session performed with GPT-5.6 Luna. It intentionally contains both sides of the comparison so the results do not depend on earlier branches, pull requests, or files outside this folder.

## Dataset

| File | Contents |
|---|---|
| `hdd-before-2026-09-07.md` | Original machine, HDD, software state, methods, limitations, and measured before results |
| `hdd-before-2026-09-07.tsv` | Machine-readable HDD-before metrics |
| `ssd-after-2026-09-12.md` | Clean post-upgrade SSD results, system state, commands, and comparison |
| `ssd-after-2026-09-12.tsv` | Machine-readable before/after metrics |

## Headline Comparison

| Metric | HDD before | SSD after |
|---|---:|---:|
| Direct sequential write, 512 MiB | 69.5 MB/s | 169 MB/s |
| Direct sequential read, 512 MiB | 127 MB/s | 292 MB/s |
| `fio` 4 KiB random read, QD1 | 138 IOPS | 7,436 IOPS |
| `fio` 4 KiB random read, QD32 | 138 IOPS | 55,295 IOPS |
| `fio` QD1 random-read average latency | 7.195 ms | 0.1335 ms |
| Direct `ioping` 4 KiB average latency | 10.6 ms | 0.2107 ms |
| Graphical target time | 16.424 s | 9.487 s |

## Interpretation

The clearest day-to-day improvement is random storage latency and queue handling. The HDD remained around 138 random 4 KiB IOPS at QD1 and QD32, while the SSD reached 7,436 and 55,295 IOPS respectively. This is the storage behavior most likely to affect application launches, package operations, filesystem metadata, swapping, and general UI stalls.

The total boot time is not used as a clean device comparison: the SSD run had a 17.192-second loader phase, while the HDD run had 4.739 seconds. Userspace and graphical-target timings are recorded separately. CPU SHA-256 scores are controls and are not attributed to the SSD.

## Provenance

- Before capture: 2026-09-07, Seagate ST1000LM035-1RK172 5400 RPM SMR SATA HDD on `/dev/sda2`.
- After capture: 2026-09-12, Timetec 35TT2280SATA-512GB SATA SSD on `/dev/sdb2`.
- Same laptop, Intel Core i7-8550U, 12 GiB RAM, CachyOS, and LTS kernel family.
- The improved before run used `fio` 3.42, `ioping` 1.3, and `hyperfine` 1.20.0; the original capture also includes lower-fidelity measurements from tools available at that time.
- Generated benchmark files were deleted after each run.
