# SSD Migration — HDD → Timetec M.2 SATA (2026-09-12)

Companion to [README.md](README.md). Covers the full SSD upgrade performed Sep 12 2026: hardware install, OS clone, boot migration, verification, and power config for the now-idle HDD. Written as a reproduction guide for similar laptops.

Machine: HP Pavilion 15-cc6xx (see README §1 for full hardware/software stack).

---

## 1. Hardware

### 1.1 Drive selection

| Drive | Status |
|---|---|
| **Old:** Seagate ST1000LM035-1RK172, 1 TB 5400rpm **SMR** HDD (2.5" SATA bay) | Retained as unmounted cold-storage fallback |
| **New:** Timetec 35TT2280SATA-512GB, 512 GB M.2 **SATA** (DRAM-less) | Boot/OS drive |

- 15-cc6xx M.2 slot is **2280, SATA-only** — NVMe drives will NOT work (confirmed again on install).
- Budget DRAM-less SATA SSD: sequential ~330-360 MB/s measured. The real win over the SMR HDD is random IO (~100x) and the absence of SMR write stalls.
- DRAM vs DRAM-less: the FTL mapping table lives in onboard DRAM vs NAND/HMB. Matters for heavy random IO, not typical desktop use.

### 1.2 Install notes (HP Pavilion 15-cc6xx)

- Bottom cover: Phillips screws, pry the seam.
- **Disconnect the internal battery cable from the motherboard first** — no removable battery on this model.
- M.2 slot is near the drive bay / board center. Board may ship **without the M.2 standoff screw** — check the SSD package (Timetec includes one).
- Leave the drive's label sticker on; connector edge goes in bare.
- Verify after install: `lsblk` shows the drive; SATA link negotiates **6.0 Gbps** (`/sys/class/ata_link/*/sata_spd`); SMART shows 0 power-on hours / 0 realloc / 0 CRC.

### 1.3 Out-of-box benchmarks (direct I/O, 2 GiB)

| Drive | Seq write | Seq read |
|---|---|---|
| ST1000LM035 HDD (baseline, Sep 7) | 113 MB/s | 60 MB/s |
| Timetec SSD | 362 MB/s | 331 MB/s |

Raw data in [`../ssd/`](../ssd/). Subjective: boot and app startup ~10x faster.

---

## 2. OS migration

### 2.1 Approach

Target: byte-identical copy of the running system onto the new drive, old disk untouched as fallback.

Final layout on the SSD (`/dev/sdb`), mirroring the HDD layout:

| Partition | Size | FS | Content |
|---|---|---|---|
| `sdb1` | 4 GiB | FAT32 (ESP) | Limine + kernels/initramfs (ESP mounted at `/boot`) |
| `sdb2` | 472.9 GiB | btrfs (`compress=zstd:3`) | subvolumes `@`, `@home`, `@root`, `@srv`, `@cache`, `@tmp`, `@log` + `var/lib/portables`, `var/lib/machines`, `.snapshots` |

### 2.2 First attempt: `btrfs send/receive` — FAILED

`btrfs send` of the root subvolume died with:

```
ERROR: crc32 mismatch in command
ERROR: failed to read stream from kernel: Broken pipe
```

Kernel-level stream corruption bug (known flaky area of `btrfs send`, kernel 6.18). Retry not attempted; fell back to rsync.

### 2.3 Final method: subvolume-create + rsync (worked cleanly)

Script: [`clone-ssd.sh`](clone-ssd.sh) (reconstructed from the session; the `/tmp` original was lost). Outline:

1. **Safety gate**: verify target model string matches the Timetec before touching anything.
2. Partition `sdb` (GPT: 4G ESP + rest btrfs), `mkfs.vfat -F32`, `mkfs.btrfs`.
3. Mount source top-level (subvolid=5) **read-only**, target with `compress=zstd:3,noatime`.
4. Enumerate all 46 source subvolumes (`btrfs subvolume list`), then for each:
   - `btrfs subvolume create` on target,
   - `rsync -aHAX` with `--exclude` of nested subvol paths, so no double-copy.
5. Verify subvolume counts match (46/46).
6. `rsync` the ESP (`/boot/` → new ESP): Limine binary, `limine.conf`, hashed kernel dirs (`bd4ce12…/`), memtest86+, splash.
7. **UUID fixes** (old → new) in the *cloned* copies:
   - ESP `/limine.conf`: all `root=UUID=…` occurrences (64 refs incl. snapshot entries)
   - Target `/@/etc/fstab`: ESP + btrfs UUIDs (8 mount lines)
   - Target `/@/etc/default/limine`: `KERNEL_CMDLINE` root UUID (so future `limine-update` runs keep generating SSD UUIDs)
8. New NVRAM entry: `efibootmgr -c -d /dev/sdb -p 1 -L "Limine SSD" -l '\EFI\limine\limine_x64.efi'` + set `BootOrder` SSD-first.
9. Unmount, `sync`.

Total data: ~23 GiB on-disk (9.3 GiB used at clone time + snapshot content), a few minutes over SATA.

### 2.4 Config deltas after first SSD boot

| File / setting | Change |
|---|---|
| `/etc/fstab` | All UUIDs → SSD (`634D-2977` ESP, `33bbce2f-…` btrfs) — done in clone step, verified |
| `/etc/default/limine` | `KERNEL_CMDLINE[default]` root=UUID → SSD — done in clone step, verified |
| `/boot/limine.conf` | root= UUIDs → SSD (done in clone step); **`timeout: 5` left as-is** |
| `/etc/udev/rules.d/69-hdd-spindown.rules` | **New** — see §3.1 |
| UEFI NVRAM | `Boot0001` "Limine SSD" created; `BootOrder` = `0001,0002,0003,0000,2001,3002` |

Everything else (all README §2 modifications) cloned as-is and verified working.

---

## 3. Power: parking the now-unused HDD

### 3.1 Problem found

Unmounted ≠ spun down. Linux does not auto-standby SATA disks: `hdparm -C /dev/sda` reported `active/idle` even with nothing mounted (~0.9–1.3 W draw). No smartd, no disk swap (zram-only), nothing else touching it.

### 3.2 Fix

Immediate: `hdparm -B 128 -S 60 /dev/sda && hdparm -y /dev/sda` → `standby`.

Persistent — `/etc/udev/rules.d/69-hdd-spindown.rules`:

```
# Spin down the old HDD (idle bulk storage) after 5 minutes
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sda", ATTRS{model}=="ST1000LM035-1RK172*", RUN+="/usr/bin/hdparm -B 128 -S 60 /dev/sda"
```

(`-S 60` = 5 min idle timer; `-B 128` = moderate APM. Model-matched so it survives device renumbering.) Verified: `standby` held for 45s+ with no wake-ups.

### 3.3 Expected gain

ST1000LM035: ~0.9–1.3 W idle → ~0.1–0.2 W standby ⇒ **~1–1.2 W saved** ≈ 10–15% battery at this laptop's ~7 W idle. (The hoped-for 2 W was optimistic; that's spin-up/spin-down territory.) Hard measurement pending a battery-only session.

---

## 3.4 Verification (post-migration checklist)

```bash
lsblk -o NAME,MODEL,MOUNTPOINTS          # / and subvol mounts on sdb; sda unmounted
cat /proc/cmdline                        # root=UUID=33bbce2f… (SSD)
findmnt -no SOURCE /boot                 # /dev/sdb1
grep -c "root=UUID=33bbce2f" /boot/limine.conf   # 64
btrfs subvolume list / | wc -l           # 10 (7 @-subvols + portables/machines/.snapshots)
efibootmgr                               # BootCurrent 0001, SSD entry first in BootOrder
grep -rn "da20171a" /etc/                # no stale refs
hdparm -C /dev/sda                       # standby
```

`systemd-analyze` after first SSD boot: firmware 3.7s + loader 17.2s + kernel 1.4s + initrd 2.1s + userspace 10.9s. The 17.2s loader time is suspected one-off (first boot after clone: firmware re-enumeration/TPM re-measure), NOT a menu timeout (`timeout: 5` caps that at 5s) — re-measure on a subsequent boot before drawing conclusions.

---

## 4. Known state / open items

1. **Snapshot history on the SSD is gone.** The 38 snapper snapshots were cloned (46/46 subvolumes verified), but snapper-cleanup on first SSD boot treated them as orphans and purged subvolumes + metadata. All snapshots remain intact on the HDD (boot the old install via F10 → "Limine" if ever needed). Going forward snapper works normally on the SSD.
2. **HDD retains the full old install** (bootable via `Boot0002` "Limine"). Decision to wipe/repurpose deferred. When it happens: delete NVRAM entries `Boot0002` (old Limine) and `Boot0000` (generic HDD), then repartition.
3. **Stale files on SSD ESP** (harmless, self-heal): `/boot/limine.conf.old`, `limine_history/snapshots.json{,.old}` still reference old UUIDs. Regenerated by `limine-update` / `limine-snapper-sync`.
4. `limine.conf` `timeout: 5` kept (user preference).
5. **`limine-enroll-config` note**: `ENABLE_VERIFICATION=yes` is cloned as-is; the SSD's `limine_x64.efi` is a byte-copy of the enrolled binary and boots fine with the sed-updated config. All future boot-config changes should go through `limine-update` on the running (SSD) system — ESP is `/boot`, so tooling just works.
6. HDD spindown measurement (§3.3) pending.

---

## 5. Gotchas / lessons (for reproducing on other laptops)

1. **`btrfs send/receive` can die mid-stream** (`crc32 mismatch`, kernel 6.18). The subvolume-create + `rsync -aHAX` + per-subvol excludes method is a robust fallback and compresses identically (target fs does the compression).
2. **Exclude nested subvolumes when rsyncing a parent**, or you copy their contents twice as plain dirs and break the subvol structure.
3. **UUIDs live in more places than fstab**: bootloader config (incl. per-snapshot entries), `/etc/default/limine` (kernel cmdline), and anything else a `grep -r <old-uuid> /etc` on the *cloned* copy surfaces.
4. **UEFI boot entry hygiene**: `efibootmgr -c/-o` needs the disk + partno; entry numbers shift after firmware updates — always re-list (`efibootmgr`) before setting order. Stale entries for removed disks are harmless while ordering favors the live one.
5. **Unmounted SATA drives keep spinning** on Linux. Park them (`hdparm -y`) + persist with a udev rule, or they idle-burn ~1 W forever.
6. **SATA-only M.2 slots are common in 2016–2018 laptops** — check before buying NVMe. This board (15-cc6xx) takes 2280 SATA only.
7. **Clone from a running system is fine** for btrfs+rsync (consistent-enough for /, /home; packages + snapshots tolerate it), but do it right after a fresh sync and don't run package operations during the copy.
8. Keep the old disk untouched until the new install has survived a few days — it is simultaneously your rollback path, snapshot archive, and A/B test for "is it the disk?"
