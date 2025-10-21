#!/bin/bash
set -e

echo "================================================"
echo " Raspberry Pi USB SSD 自動移行スクリプト"
echo " (オリジナル準拠＋進捗表示＋autosuspend無効)"
echo "================================================"

# 前提条件チェック
check_prerequisites() {
    echo ">>> 前提条件チェック..."
    
    if ! lsblk | grep -q sda; then
        echo "エラー: USB SSDが検出されません (/dev/sda が存在しません)"
        exit 1
    fi
    
    if ! command -v rsync &> /dev/null; then
        echo "必要なパッケージをインストールしています..."
        sudo apt update
        sudo apt install -y rsync parted smartmontools
    fi
    
    echo "✓ 前提条件OK"
}

# USB SSD情報確認
show_usb_info() {
    echo ">>> USB SSD情報確認..."
    if command -v smartctl &> /dev/null; then
        sudo smartctl -i -d scsi /dev/sda | grep -E "Vendor|Product|Serial|User Capacity" || echo "詳細情報取得失敗"
    else
        echo "smartctl が見つかりません。sudo apt install smartmontools で導入できます"
    fi
    echo ""
}

# USB SSD初期化
init_usb_ssd() {
    echo ">>> USB SSD初期化..."
    
    sudo umount /dev/sda* 2>/dev/null || true
    
    echo "先頭領域を消去して初期化します..."
    sudo dd if=/dev/zero of=/dev/sda bs=1M count=100 status=progress
    
    echo "新しいパーティションテーブルを作成..."
    sudo parted /dev/sda --script mklabel msdos
    sudo parted /dev/sda --script mkpart primary fat32 1MiB 513MiB
    sudo parted /dev/sda --script set 1 boot on
    sudo parted /dev/sda --script mkpart primary ext4 513MiB 100%
    
    sleep 3
    sudo partprobe /dev/sda
    sleep 2
    
    echo "✓ SSD初期化・パーティション作成完了"
}

# ファイルシステム作成
create_filesystems() {
    echo ">>> ファイルシステム作成..."
    sudo mkfs.vfat -F 32 -n "BOOT" /dev/sda1
    sudo mkfs.ext4 -F -L "ROOT" /dev/sda2
    echo "✓ ファイルシステム作成完了"
}

# システムコピー
copy_system() {
    echo ">>> システムコピー開始..."

    sudo mkdir -p /mnt/{boot,root}
    sudo mount /dev/sda1 /mnt/boot
    sudo mount /dev/sda2 /mnt/root

    echo ">>> boot パーティションコピー (進捗表示あり)..."
    if [ -d /boot/firmware ]; then
        sudo rsync -axHA --info=progress2 /boot/firmware/ /mnt/boot
    else
        sudo rsync -axHA --info=progress2 /boot/ /mnt/boot
    fi

    echo ">>> root パーティションコピー対象サイズを計算中..."
    TOTAL_SIZE=$(sudo du -sbx / \
        --exclude=/boot --exclude=/dev --exclude=/proc \
        --exclude=/sys --exclude=/tmp --exclude=/run \
        --exclude=/mnt --exclude=/media --exclude=/lost+found \
        --exclude=/var/swap \
        | cut -f1)
    echo "コピー対象合計サイズ: $(numfmt --to=iec $TOTAL_SIZE) ($TOTAL_SIZE bytes)"

    echo ">>> root パーティションコピー (進捗表示あり)..."
    sudo rsync -axHA --info=progress2 /* /mnt/root \
        --exclude /boot \
        --exclude /dev/* \
        --exclude /proc/* \
        --exclude /sys/* \
        --exclude /tmp/* \
        --exclude /run/* \
        --exclude /mnt/* \
        --exclude /media/* \
        --exclude /lost+found \
        --exclude /var/swap

    echo "✓ システムコピー完了"
}

# fstab / cmdline.txt の自動修正
update_boot_config() {
    echo ">>> fstab と cmdline.txt を自動修正..."

    ROOT_UUID=$(blkid -s PARTUUID -o value /dev/sda2)
    BOOT_UUID=$(blkid -s PARTUUID -o value /dev/sda1)

    # fstab 書き換え
    cat <<EOF | sudo tee /mnt/root/etc/fstab
PARTUUID=${ROOT_UUID}  /               ext4  defaults,noatime  0 1
PARTUUID=${BOOT_UUID}  /boot/firmware  vfat  defaults          0 2
EOF

    # cmdline.txt 書き換え
    echo "console=serial0,115200 console=tty1 root=PARTUUID=${ROOT_UUID} rootfstype=ext4 fsck.repair=yes rootwait usbcore.autosuspend=-1" \
      | sudo tee /mnt/boot/cmdline.txt

    echo "✓ fstab と cmdline.txt を更新しました"
}

# USB autosuspend 無効化
disable_autosuspend() {
    echo ">>> USB autosuspend を無効化しています..."

    echo 'ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"' \
        | sudo tee /etc/udev/rules.d/50-usb-autosuspend.rules

    echo "✓ USB autosuspend 無効化設定完了"
}

# メイン処理
check_prerequisites
show_usb_info
init_usb_ssd
create_filesystems
copy_system
update_boot_config
disable_autosuspend

echo "================================================"
echo " USB SSDへのシステム移行が完了しました"
echo " 次の手順:"
echo " 1. sudo umount /mnt/boot /mnt/root"
echo " 2. sudo shutdown -h now"
echo " 3. SDカードを取り外して再起動"
echo "================================================"
