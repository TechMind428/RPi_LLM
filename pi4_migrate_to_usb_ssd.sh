#!/bin/bash
set -e

echo "================================================"
echo " Pi 4B USB SSD OS移行"
echo "================================================"

# 前提条件チェック
check_prerequisites() {
    echo ">>> 前提条件チェック..."
    
    if ! lsblk | grep -q sda; then
        echo "エラー: USB SSDが検出されません"
        exit 1
    fi
    
    if ! command -v rsync &> /dev/null; then
        echo "rsyncをインストールしています..."
        sudo apt update && sudo apt install -y rsync parted
    fi
    
    echo "✓ 前提条件OK"
}

# USB SSD情報確認
confirm_usb_ssd() {
    echo ">>> USB SSD情報確認..."
    
    echo "USB SSD情報:"
    sudo hdparm -I /dev/sda | grep -E "Model|Serial" || echo "詳細情報取得失敗"
    
    echo ""
    echo "現在のパーティション:"
    sudo fdisk -l /dev/sda 2>/dev/null || echo "パーティション情報取得失敗"
    
    echo ""
    echo "警告: USB SSDの全データが削除されます！"
    echo "続行してよろしいですか? (yes/no)"
    read -r response
    
    if [ "$response" != "yes" ]; then
        echo "処理を中止しました"
        exit 0
    fi
}

# USB SSD初期化
init_usb_ssd() {
    echo ">>> USB SSD初期化..."
    
    # アンマウント
    sudo umount /dev/sda* 2>/dev/null || true
    
    # 簡単な初期化
    echo "USB SSD初期化中..."
    sudo dd if=/dev/zero of=/dev/sda bs=1M count=100 status=progress
    
    echo "✓ USB SSD初期化完了"
}

# パーティション作成
create_partitions() {
    echo ">>> パーティション作成..."
    
    # MBRパーティションテーブル作成（Pi 4B USB起動用）
    sudo parted /dev/sda --script mklabel msdos
    sudo parted /dev/sda --script mkpart primary fat32 1MiB 513MiB
    sudo parted /dev/sda --script set 1 boot on
    sudo parted /dev/sda --script mkpart primary ext4 513MiB 100%
    
    # パーティション認識待機
    sleep 3
    sudo partprobe /dev/sda
    sleep 2
    
    echo "✓ パーティション作成完了"
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
    echo ">>> システムコピー中（12-18分程度）..."
    
    sudo mkdir -p /mnt/{boot,root}
    sudo mount /dev/sda1 /mnt/boot
    sudo mount /dev/sda2 /mnt/root
    
    # ブートパーティションコピー
    echo "ブートファイルコピー中..."
    if [ -d /boot/firmware ]; then
        sudo cp -a /boot/firmware/* /mnt/boot/
    else
        sudo cp -a /boot/* /mnt/boot/
    fi
    
    # ルートパーティションコピー
    echo "システムファイルコピー中..."
    sudo rsync -axHAWXS --numeric-ids --info=progress2 \
        --exclude=/boot \
        --exclude=/boot/firmware \
        --exclude=/proc \
        --exclude=/sys \
        --exclude=/dev \
        --exclude=/run \
        --exclude=/mnt \
        --exclude=/media \
        --exclude=/lost+found \
        --exclude=/tmp \
        --exclude=/var/tmp \
        --exclude=/var/log \
        / /mnt/root/
    
    # 必要なディレクトリ作成
    sudo mkdir -p /mnt/root/{proc,sys,dev,run,mnt,media,tmp,var/tmp,var/log}
    sudo mkdir -p /mnt/root/boot
    
    # 権限修正
    sudo chmod 1777 /mnt/root/tmp
    sudo chmod 1777 /mnt/root/var/tmp
    
    echo "✓ システムコピー完了"
}

# ブート設定更新
update_boot_config() {
    echo ">>> ブート設定更新..."
    
    # fstab更新
    sudo tee /mnt/root/etc/fstab << FSTAB
proc            /proc           proc    defaults          0       0
/dev/sda1       /boot           vfat    defaults          0       2
/dev/sda2       /               ext4    defaults,noatime  0       1
tmpfs           /var/tmp        tmpfs   defaults,noatime,mode=1777,size=512m  0 0
FSTAB
    
    # cmdline.txt更新（Pi 4B用）
    sudo sed -i 's|root=PARTUUID=[^ ]*|root=/dev/sda2|g' /mnt/boot/cmdline.txt
    
    echo "✓ ブート設定更新完了"
}

# クリーンアップ
cleanup() {
    echo ">>> クリーンアップ..."
    sudo umount /mnt/boot /mnt/root 2>/dev/null || true
    sudo rmdir /mnt/boot /mnt/root 2>/dev/null || true
    echo "✓ クリーンアップ完了"
}

# メイン実行
main() {
    check_prerequisites
    confirm_usb_ssd
    init_usb_ssd
    create_partitions
    create_filesystems
    copy_system
    update_boot_config
    cleanup
    
    echo "================================================"
    echo " USB SSD移行完了！"
    echo "================================================"
    echo "次の手順:"
    echo "1. sudo shutdown -h now で電源OFF"
    echo "2. SDカードを取り外す"
    echo "3. 電源を入れてUSB SSDから起動"
    echo "4. SSH接続: ssh admin@ollama-pi4-ssd.local"
    echo "================================================"
}

# Ctrl+C でのクリーンアップ
trap cleanup EXIT
main "$@"
