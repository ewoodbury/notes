#!/bin/bash
# clone-ssd.sh — migrate a running CachyOS btrfs+Limine install to a new SATA drive
# Used 2026-09-12: Seagate 1TB HDD (/dev/sda) -> Timetec 512GB M.2 SATA (/dev/sdb)
# See ssd-upgrade-2026-09-12.md for context. Reconstructed from the session
# (original was in /tmp). DRY-RUN MENTALITY: verify every device variable below
# against YOUR machine before running. Root required.
#
# Note: an earlier version used btrfs send/receive, which died with
# "ERROR: crc32 mismatch in command" (kernel 6.18 bug). This rsync-based
# version is the one that worked.
set -euo pipefail

SRC_BTRFS=/dev/sda2          # source btrfs partition (READ-ONLY usage)
DST=/dev/sdb                 # target disk - WILL BE PARTITIONED/FORMATTED
DST_ESP=/dev/sdb1
DST_ROOT=/dev/sdb2
M=/mnt/clone                 # scratch mountpoint, must not exist/be in use
OLD_ESP_UUID=D349-0D22
OLD_BTRFS_UUID=da20171a-7e4b-4e57-af28-ec831833c51c

log() { echo -e "\n=== $* ==="; }

log "SAFETY CHECK: verifying /dev/sdb is the expected target"
model=$(cat /sys/block/sdb/device/model)
echo "sdb model: $model"
case "$model" in *Timetec*) ;; *) echo "FATAL: sdb is not the expected drive, aborting"; exit 1;; esac
mountpoint -q "$M" && { echo "$M already in use, aborting"; exit 1; }
for m in "$M/esp" "$M/dst" "$M/src"; do mountpoint -q "$m" && umount "$m"; done
partprobe "$DST" 2>/dev/null || true

log "1. Partitioning + formatting target"
parted -s "$DST" -- mklabel gpt \
  mkpart ESP fat32 1MiB 4097MiB \
  set 1 esp on \
  mkpart root btrfs 4097MiB 100%
partprobe "$DST"; sleep 2
mkfs.vfat -F 32 -n ESP_SSD "$DST_ESP"
mkfs.btrfs -L CACHYOS_SSD "$DST_ROOT"
NEW_ESP_UUID=$(blkid -s UUID -o value "$DST_ESP")
NEW_BTRFS_UUID=$(blkid -s UUID -o value "$DST_ROOT")
echo "new ESP UUID: $NEW_ESP_UUID / new btrfs UUID: $NEW_BTRFS_UUID"

log "2. Mount source (read-only top-level) and target"
mkdir -p "$M"/{src,dst,esp}
mount -o ro,subvolid=5 "$SRC_BTRFS" "$M/src"
mount -o compress=zstd:3,noatime "$DST_ROOT" "$M/dst"

log "3. Per-subvolume create + rsync (fallback for btrfs send crc32 bug)"
mapfile -t SUBVOLS < <(btrfs subvolume list "$M/src" | awk '{print $NF}')
SRC_COUNT=${#SUBVOLS[@]}
echo "found $SRC_COUNT subvolumes"
i=0
for p in "${SUBVOLS[@]}"; do
  i=$((i+1))
  parentdir=$(dirname "$p")
  mkdir -p "$M/dst/$parentdir"
  btrfs subvolume create "$M/dst/$p" >/dev/null
  excl=()
  for q in "${SUBVOLS[@]}"; do
    if [ "$q" != "$p" ] && [[ "$q" == "$p"/* ]]; then
      excl+=(--exclude="/${q#"$p"/}")
    fi
  done
  echo "[$i/$SRC_COUNT] rsync: $p (nested-subvol excludes: ${#excl[@]})"
  rsync -aHAX "${excl[@]}" "$M/src/$p/" "$M/dst/$p/"
done

log "4. Verify subvolume counts"
DST_COUNT=$(btrfs subvolume list "$M/dst" | wc -l)
echo "source: $SRC_COUNT  target: $DST_COUNT"
[ "$SRC_COUNT" = "$DST_COUNT" ] || { echo "SUBVOL COUNT MISMATCH"; exit 1; }

log "5. Copy ESP (Limine, kernels, memtest, splash)"
mount "$DST_ESP" "$M/esp"
rsync -rlptDH --stats /boot/ "$M/esp/" | grep -E 'Number of files|Number of regular|speedup'

log "6. UUID fixes in cloned limine.conf (all entries incl. snapshots)"
sed -i "s|root=UUID=$OLD_BTRFS_UUID|root=UUID=$NEW_BTRFS_UUID|g" "$M/esp/limine.conf"
grep -o 'root=UUID=[a-f0-9-]*' "$M/esp/limine.conf" | sort -u

log "7. UUID fixes in cloned fstab + /etc/default/limine"
sed -i "s|UUID=$OLD_ESP_UUID|UUID=$NEW_ESP_UUID|g; s|UUID=$OLD_BTRFS_UUID|UUID=$NEW_BTRFS_UUID|g" "$M/dst/@/etc/fstab"
[ -f "$M/dst/@/etc/default/limine" ] && \
  sed -i "s|UUID=$OLD_BTRFS_UUID|UUID=$NEW_BTRFS_UUID|g" "$M/dst/@/etc/default/limine"
echo "remaining old-UUID refs in cloned /etc (should be none):"
grep -rl "$OLD_BTRFS_UUID" "$M/dst/@/etc/" 2>/dev/null || echo "  (none)"

log "8. UEFI boot entry + order"
efibootmgr -c -d "$DST" -p 1 -L "Limine SSD" -l '\EFI\limine\limine_x64.efi' >/dev/null
NEWBOOT=$(efibootmgr | awk '/Limine SSD/{print substr($1,4,4)}')
OLDBOOT=$(efibootmgr | awk '/Limine\t/{print substr($1,4,4)}')
efibootmgr -o "${NEWBOOT},${OLDBOOT:-0002},3002,0000,2001,2002,2004" 2>/dev/null || efibootmgr -o "${NEWBOOT},0002"
efibootmgr | head -8

log "9. Unmount + sync"
umount "$M/esp" "$M/dst" "$M/src"
sync
echo "######## CLONE COMPLETE — reboot, select the new entry in firmware, verify ########"