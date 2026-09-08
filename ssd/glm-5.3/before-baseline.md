# SSD Upgrade — "Before" Benchmark Baseline (HDD) — run `glm-5.3`

> Separate concurrent baseline run on branch `glm-5.3`. Do not mix with the
> `luna-5.6` run in [`ssd/README.md`](../README.md) /
> [`ssd/baseline-2026-09-07.tsv`](../baseline-2026-09-07.tsv) — different
> methods (fio vs dd) and different system states. Compare after-upgrade runs
> against each baseline individually.

Date: 2026-09-07 · Before: Seagate ST1000LM035 1TB 5400rpm SMR HDD → After: new SSD
OS: CachyOS, kernel 6.18.48-1-cachyos-lts · i7-8550U · 12GB RAM + 11.6G zram
Root fs: btrfs (compress=zstd:3, noatime, discard=async)

## Why this matters
- At near-idle, vmstat showed **30–54% iowait** with constant swap-in/out (si/so > 0 continuously).
- **7.3G of 11.6G zram swap full**, spilling to the HDD. This is the dominant day-to-day bottleneck.
- Boot: 31.5s total; device init alone 10.7s; plocate-updatedb 36s, man-db 26s (disk-bound).

## Disk benchmarks (fio, direct=1, files in /home on sda2)
| Test | Result |
|---|---|
| Seq write 1M (2G) | **80 MiB/s** (IOPS 80, huge variance: min 4 / max 132 — classic SMR stalls) |
| Seq read 1M (2G) | **112 MiB/s** |
| Rand 4K read (QD1) | **388 KiB/s** (~96 IOPS) |
| Rand 4K write (QD1) | **408 KiB/s** (~102 IOPS) |
| 4K latency (ioping) | avg **0.52 ms**, min 0.37 / max 0.74 (at idle; degraded under load) |

Raw outputs: `fio-quick.txt`, `ioping.txt`, `system-state.txt` (same directory).

## SMART (full text in smartctl-baseline.txt)
- Overall: **PASSED**; 0 reallocated / 0 pending / 0 uncorrectable sectors
- 6057 power-on hours, 3110 power cycles, Load_Cycle 83392, temp 40°C
- Very high Raw_Read_Error_Rate & Seek_Error_Rate raw counts — normal for Seagate encoding, not actual failures

## System state snapshot
- Load avg 2.05 with no user activity; 8 blocked tasks (b) in vmstat
- See `system-state.txt`

## Re-run instructions (after upgrade)
```
fio --name=seq-write --rw=write --bs=1M --size=2G --direct=1
fio --name=seq-read  --rw=read  --bs=1M --size=2G --direct=1
fio --name=rand-rw-4k --rw=randrw --bs=4k --size=512M --direct=1 --runtime=15 --time_based
ioping -c 10 .
```
Compare: seq ~100 MiB/s → expect 300–550 MiB/s (SATA SSD); 4K ~100 IOPS → expect 8–40k IOPS.

## SMART baseline (recorded 21:38, verbatim key lines)
```
SMART overall-health self-assessment test result: PASSED
  5 Reallocated_Sector_Ct  100/100  RAW 0
197 Current_Pending_Sector 100/100  RAW 0
  9 Power_On_Hours         6057
193 Load_Cycle_Count       83392
194 Temperature_Celsius    40
```
