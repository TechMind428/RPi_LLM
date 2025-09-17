#!/bin/bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
START_TS="$(date +%s)"
SUCCESS=false

log() { echo "[$(date '+%F %T')] $*"; }

on_err() {
  local rc=$?
  log "✗ エラー発生 (rc=$rc) | 行:${BASH_LINENO[0]} | コマンド:'$BASH_COMMAND'"
  exit $rc
}

cleanup() {
  log ">>> クリーンアップ開始..."
  for mp in /mnt/boot /mnt/root; do
    if mountpoint -q "$mp"; then
      sudo umount "$mp" || true
    fi
  done
  for mp in /mnt/boot /mnt/root; do
    [[ -d "$mp" ]] && sudo rmdir "$mp" 2>/dev/null || true
  done
  log "✓ クリーンアップ完了"
}

on_exit() {
  local rc=$?
  cleanup
  local dur=$(( $(date +%s) - START_TS ))
  if $SUCCESS && [[ $rc -eq 0 ]]; then
    log "🎉 正常終了（${dur}s）"
    cat <<'NEXT'
================================================
 SSD移行完了！
 次の手順:
 1) sudo shutdown -h now で電源OFF
 2) SDカードを取り外す
 3) 電源を入れてSSDから起動
================================================
NEXT
  else
    log "⚠ 異常終了（rc=$rc, ${dur}s）。上のエラー行を確認してください。"
  fi
}
trap on_err ERR
trap on_exit EXIT

require_tools() {
  local missing=()
  for t in nvme smartctl parted rsync lsblk; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    log "✗ 欠如ツール: ${missing[*]}"
    exit 1
  fi
}

check_prerequisites() {
  log ">>> 前提条件チェック..."
  require_tools
  if ! lsblk -ndo NAME | grep -q '^nvme0n1$'; then
    log "✗ NVMe SSD /dev/nvme0n1 が見つかりません"
    exit 1
  fi
  log "NVMe情報:"
  sudo nvme id-ctrl /dev/nvme0n1 | grep -E "Model Number|Serial Number" || true
  log "SMARTサマリ:"
  sudo smartctl -a /dev/nvme0n1 | grep -E "Temperature|Available Spare|Data Units Written" || true

  echo ""
  echo "警告: /dev/nvme0n1 のデータは消去されます。続行しますか? (yes/no)"
  read -r ans
  [[ "$ans" == "yes" ]] || { log "中止しました"; exit 0; }
  log "✓ 前提条件OK"
}

secure_erase_ssd() {
  log ">>> SSD初期化..."
  # 念のため全パーティションをアンマウント
  sudo umount /dev/nvme0n1* 2>/dev/null || true

  if sudo nvme id-ctrl /dev/nvme0n1 | grep -q "Format NVM Supported"; then
    log "NVMe format (secure erase) 実行..."
    if sudo nvme format /dev/nvme0n1 --ses=1 --force; then
      log "✓ セキュアイレース完了"
    else
      log "⚠ 失敗: dd でゼロフィル (先頭2GiB)"
      sudo dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=2048 status=progress
    fi
  else
    log "セキュアイレース非対応: dd でゼロフィル (先頭2GiB)"
    sudo dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=2048 status=progress
  fi
  sync
  log "✓ SSD初期化完了"
}

create_partitions() {
  log ">>> パーティション作成 (GPT / ESP+ROOT)..."
  sudo parted -s /dev/nvme0n1 mklabel gpt
  sudo parted -s /dev/nvme0n1 mkpart ESP fat32 1MiB 513MiB
  sudo parted -s /dev/nvme0n1 set 1 esp on
  sudo parted -s /dev/nvme0n1 mkpart ROOT ext4 513MiB 100%
  sudo partprobe /dev/nvme0n1
  sleep 2
  lsblk -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINT /dev/nvme0n1 || true
  log "✓ パーティション作成完了"
}

create_filesystems() {
  log ">>> ファイルシステム作成..."
  sudo mkfs.vfat -F 32 -n BOOT /dev/nvme0n1p1
  sudo mkfs.ext4 -F -L ROOT /dev/nvme0n1p2
  sudo tune2fs -o discard /dev/nvme0n1p2 || true
  sync
  log "✓ ファイルシステム作成完了"
}

mount_targets() {
  log ">>> マウント..."
  sudo mkdir -p /mnt/boot /mnt/root
  sudo mount /dev/nvme0n1p1 /mnt/boot
  sudo mount /dev/nvme0n1p2 /mnt/root
  mount | grep -E '/mnt/(boot|root)' || true
  log "✓ マウント完了"
}

copy_system() {
  log ">>> システムコピー開始（進捗は rsync の行で表示）"

  # ブート
  log "— ブートパーティションコピー /boot/firmware → /mnt/boot"
  if [[ ! -d /boot/firmware ]]; then
    log "✗ /boot/firmware が見つかりません。Raspberry Pi OS Bookworm を想定しています。"
    exit 1
  fi
  sudo rsync -aHAX --delete --info=progress2 /boot/firmware/ /mnt/boot/

  # ルート
  log "— ルートパーティションコピー / → /mnt/root"
  sudo rsync -aHAXx --numeric-ids --info=progress2 \
    --exclude=/boot/firmware \
    --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
    --exclude=/mnt --exclude=/media --exclude=/lost+found \
    --exclude=/tmp --exclude=/var/tmp --exclude=/var/log \
    / /mnt/root/

  # 必要ディレクトリ再作成
  sudo mkdir -p /mnt/root/{proc,sys,dev,run,mnt,media,tmp,var/tmp,var/log}
  sudo chmod 1777 /mnt/root/tmp
  sudo chmod 1777 /mnt/root/var/tmp
  log "✓ システムコピー完了"
}

update_boot_config() {
  log ">>> ブート設定更新..."

  # fstab
  cat <<'FSTAB' | sudo tee /mnt/root/etc/fstab >/dev/null
proc            /proc           proc    defaults                                  0 0
/dev/nvme0n1p1  /boot/firmware  vfat    defaults                                  0 2
/dev/nvme0n1p2  /               ext4    defaults,noatime,discard                  0 1
tmpfs           /tmp            tmpfs   defaults,noatime,mode=1777,size=2g        0 0
tmpfs           /var/log        tmpfs   defaults,noatime,mode=0755,size=1g        0 0
tmpfs           /var/tmp        tmpfs   defaults,noatime,mode=1777,size=512m      0 0
FSTAB
  log "— /etc/fstab 更新済"

  # cmdline.txt
  if [[ -f /mnt/boot/cmdline.txt ]]; then
    log "— cmdline.txt 更新: root=/dev/nvme0n1p2, rootflags=discard"
    sudo sed -i 's|root=PARTUUID=[^ ]*|root=/dev/nvme0n1p2|g' /mnt/boot/cmdline.txt
    if ! grep -q 'rootflags=discard' /mnt/boot/cmdline.txt; then
      sudo sed -i 's/\brootwait\b/rootwait rootflags=discard/' /mnt/boot/cmdline.txt
    fi
    log "— 変更後 cmdline.txt:"
    sudo cat /mnt/boot/cmdline.txt
  else
    log "✗ /mnt/boot/cmdline.txt が見つかりません（ブートコピーに失敗している可能性）"
    exit 1
  fi

  sync
  log "✓ ブート設定更新完了"
}

main() {
  echo "================================================"
  echo "  安全なSSD移行スクリプト（改良ログ版） - ${SCRIPT_NAME}"
  echo "================================================"

  check_prerequisites
  secure_erase_ssd
  create_partitions
  create_filesystems
  mount_targets
  copy_system
  update_boot_config

  SUCCESS=true
}

main "$@"
