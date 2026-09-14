# SSD Migration Log — 2026-09-12/13

This document records the physical install, in-place clone, and boot-configuration work that migrated the running CachyOS installation from the 1 TB HDD (`sda`, Seagate ST1000LM035) to a new M.2 SATA SSD (`sdb`, Timetec 35TT2280SATA-512GB). The HDD was never written to except for temporary mount metadata cleanup and remains a complete bootable fallback with all snapper snapshots intact. Work was performed live (clone while running) from the HDD system using `pkexec`-elevated shell steps.

## Hardware and first checks

| Item | Detail |
|---|---|
| New drive | Timetec 35TT2280SATA-512GB, 476.9 GiB, serial `QYR260622B5D0231` |
| Slot | Empty M.2 2280 SATA slot of the HP Pavilion 15-cc6xx; HDD stays in the 2.5" bay |
| SATA link | 6.0 Gbps negotiated on both ports |
| SMART | PASSED; 0 power-on hours, 0 reallocated, 0 uncorrectable, 0 UDMA CRC errors, ~40 C |
| Quick throughput | 362 MB/s sequential write, 331 MB/s sequential read (2 GiB, direct I/O, raw device) |
| Bootloader | Limine (CachyOS default), ESP at `/boot` (4 GiB vfat), kernels under `/boot/<machine-id>/` with SHA-256-suffixed paths verified by Limine |

## Target layout

| Partition | Size | FS | UUID |
|---|---|---|---|
| `sdb1` ESP | 4 GiB | vfat, label `ESP_SSD` | `634D-2977` (PARTUUID `1388833a-d90b-4469-a62a-8124b81ca293`) |
| `sdb2` root | 472.9 GiB | btrfs, label `CACHYOS_SSD`, `compress=zstd:3,noatime` | `33bbce2f-ba45-4678-921f-b7ac97799e88` |

## Clone method and what was copied

1. Partitioned and formatted `sdb` to mirror the source layout (4 GiB ESP + rest btrfs).
2. Source subvolumes enumerated via `btrfs subvolume list` on a read-only `subvolid=5` mount: 46 total — 10 live subvolumes (`@`, `@home`, `@root`, `@srv`, `@cache`, `@tmp`, `@log`, `@/var/lib/portables`, `@/var/lib/machines`, `@/.snapshots`) plus 36 snapper snapshot subvolumes.
3. **`btrfs send`/`receive` failed** on this kernel (`6.18.48-1-cachyos-lts`) with `ERROR: crc32 mismatch in command` on the first stream. Fallback method used instead: create each target subvolume with `btrfs subvolume create`, then `rsync -aHAX` contents, excluding paths of nested subvolumes from each parent's transfer. All 10 live subvolumes verified identical by recursive file count and `diff` of sorted `find` output.
4. **Snapper snapshot contents were intentionally not copied.** The 36 snapshots share data blocks via COW (total filesystem usage only ~9.3 GiB), but rsync would materialize each snapshot in full — roughly 30-90 GiB of writes and many hours of reads from the SMR HDD. Instead, a fresh empty `@/.snapshots` subvolume was created; `limine-snapper-sync`/`snapper` rebuild snapshot history on the SSD going forward. All old snapshots remain on the HDD.
5. ESP copied with `rsync -rlptDH` (35 files: Limine binary, both kernels and initramfs images, splash, memtest). Kernel file names contain embedded SHA-256 hashes; since files were copied byte-identical, Limine's integrity checks remain valid.
6. UUID references updated in the clone: `limine.conf` (`root=UUID=` in every entry), cloned `/etc/fstab` (ESP + all btrfs lines), and `/etc/default/limine` (used by `limine-entry-tool` when regenerating the menu). No remaining references to the old UUIDs.
7. Leftover cleanup from the first failed attempt: a stray read-only snapshot at `@/mnt/clone/snap/@` was deleted from the live filesystem, and junk `/mnt/clone` directories were removed from the clone.

## UEFI boot configuration

| Entry | Target | Role |
|---|---|---|
| `Boot0001` "Limine SSD" | `HD(1,GPT,1388833a…)`/`\EFI\limine\limine_x64.efi` (SSD ESP) | **Primary** |
| `Boot0003` "EFI Hard Drive 1 (Timetec…)" | SSD ESP fallback path | Second |
| `Boot0002` "Limine" | `HD(1,GPT,8c00d25b…)`/`\EFI\limine\limine_x64.efi` (HDD ESP) | Fallback boot to old system |
| `Boot0000` "EFI Hard Drive (ST1000LM035…)" | HDD ESP fallback path | Fallback |

- First boot was forced with `efibootmgr -n 0001` (one-shot BootNext).
- A persistent `BootOrder` fix initially failed: `efibootmgr -o` rejected entry `2002`, a stale firmware virtual entry not present as a real variable, so the fix silently didn't apply and the machine kept booting the HDD's Limine (BootNext is consumed after one boot). This was misread at the time as firmware reordering.
- A corrected `efibootmgr -o 0001,0003,0002,0000,2001,3002` was applied on 2026-09-13, but a reboot test proved the HP firmware **enforces its own stored boot order and rewrites NVRAM at every boot** (BootOrder was reverted to HDD-first, and the previously nonexistent `2002`/`2004` virtual entries reappeared in the list). `efibootmgr` order changes therefore do not persist on this machine.
- **Final fix (2026-09-13): the HDD ESP's bootloader files were disabled** so the firmware cannot boot the HDD at all, making every boot path end at the SSD regardless of firmware ordering:
  - `/mnt/hdd-esp` ← mount `sda1`
  - `mv /mnt/hdd-esp/EFI/limine /mnt/hdd-esp/EFI/limine.off`
  - `mv /mnt/hdd-esp/EFI/BOOT /mnt/hdd-esp/EFI/BOOT.off`
  - `Boot0002` (Limine, HDD) and `Boot0000` (HDD fallback) now target nonexistent files and fail through to `Boot0001`/`Boot0003` (SSD).

### Restoring the HDD fallback boot (if ever needed)

```bash
sudo mkdir -p /mnt/hdd-esp && sudo mount /dev/sda1 /mnt/hdd-esp
sudo mv /mnt/hdd-esp/EFI/limine.off /mnt/hdd-esp/EFI/limine
sudo mv /mnt/hdd-esp/EFI/BOOT.off /mnt/hdd-esp/EFI/BOOT
sudo umount /mnt/hdd-esp
```

After restoring, `Boot0002`/`Boot0000` work again and F9 offers the HDD's Limine. The SSD will still boot as long as BootOrder or a BootNext points at it; re-disable (re-run the two `mv` commands above) afterwards if the firmware misbehaves again. Alternative firmware-level fix not yet attempted: F10 → Boot Options → UEFI Boot Order, placing the Timetec/Limine SSD entry first — HP's own setting is the source of truth and should stick.

## Outcome and follow-ups

- 2026-09-12: first SSD boot succeeded (via BootNext); ~8 hours of use, noticeably faster general responsiveness.
- 2026-09-13: subsequent reboots landed on the HDD despite a correct BootOrder, exposing the HP firmware NVRAM rewrite behavior; resolved permanently by disabling the HDD ESP bootloader (see above). HDD fallback is now intentionally unavailable until restored via the commands above.
- Old snapper snapshot menu entries in the cloned `limine.conf` point at snapshots that only exist on the HDD; ignore them on the SSD — the menu is regenerated after the first new snapshot. (Confirmed 2026-09-13: `limine.conf` regenerated, snapshot entries now reference the SSD's fresh history.)
- HDD `sda` is untouched: full OS, all 36 snapshots, and the old Limine entry (`Boot0002`) still boot it. Once the SSD setup is confirmed stable, decide whether to keep it as a data/backup drive or repurpose it.
- Post-upgrade benchmark suite (per the comparison protocol in the README) has not yet been run.

## Final verification (2026-09-13, after hard-power-loss boot incident)

Full audit after the battery-drain reboot that briefly landed on the HDD:

| Check | Result |
|---|---|
| NVRAM | **Only SSD entries remain**: `Boot0001` "Limine SSD" (first), `Boot0003` Timetec device fallback, firmware virtual entries. `Boot0000`/`Boot0002` (HDD) are gone from NVRAM entirely |
| HDD ESP | Only `EFI/limine.off` + `EFI/BOOT.off` present — no bootable binaries |
| Current boot | SSD confirmed (`root=UUID=33bbce2f…`, `/boot` = `sdb1`, `BootCurrent: 0001`) |
| SSD-side configs intact | All 5 kernel mitigation flags, `kernel.sysrq=1`, `vm.dirty_bytes=268435456`, WiFi powersave off, XFCE compositor off, `limine.conf` + `/etc/default/limine` + fstab all on SSD UUIDs, subvol `/@` mounts |
| HDD power | Re-parked to standby; `69-hdd-spindown.rules` present on the SSD install and timer re-armed (`-B 128 -S 60`). Disk wakes on manual ESP mounts and re-parks after 5 min |

**Why this sticks regardless of firmware behavior**: every real NVRAM boot entry now points at the SSD, and the HDD has no bootable EFI path even if the firmware re-adds or reorders device entries. Failure of the SSD entry falls through to `Boot0003` (same disk). The HDD fallback is restorable in 30 seconds via the commands above if ever needed (e.g. SSD failure).
