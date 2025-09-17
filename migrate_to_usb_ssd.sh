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
        sudo apt update && sudo apt install -y rsync parted smartmontools
    fi
    
    echo "✓ 前提条件OK"
}

# USB SSD情報確認
confirm_usb_ssd() {
    echo ">>> USB SSD情報確認..."
    
    echo "USB SSD情報:"
    if command -v smartctl &> /dev/null; then
        sudo smartctl -i -d scsi /dev/sda | grep -E "Vendor|Product|Serial|User Capacity" || echo "詳細情報取得失敗"
    else
        echo "smartctl が見つかりません。インストールしてください: sudo apt install smartmontools"
    fi
    
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
    
    echo ">>> boot パーティションコピー..."
    sudo rsync -axHA /boot/ /mnt/boot
    
    echo ">>> root パーティションコピー..."
    sudo rsync -axHA /* /mnt/root \
        --exclude /boot \
        --exclude /dev/* \
        --exclude /proc/* \
        --exclude /sys/* \
        --exclude /tmp/* \
        --exclude /run/* \
        --exclude /mnt/* \
        --exclude /media/* \
        --exclude /lost+found
    
    echo "✓ システムコピー完了"
}

# メイン処理
check_prerequisites
confirm_usb_ssd
init_usb_ssd
create_partitions
create_filesystems
copy_system

echo "================================================"
echo " USB SSDへのシステム移行が完了しました"
echo " SDカードを取り外し、USB SSDから起動できるか確認してください"
echo "================================================"
