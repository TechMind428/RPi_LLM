#!/bin/bash
echo "=========================================="
echo " USB SSD 認識確認"
echo "=========================================="

echo "1. USB デバイス確認"
echo "----------------------------------------"
lsusb | grep -E "Mass Storage|SSD" || echo "USB SSDが見つかりません"

echo -e "\n2. ブロックデバイス確認"
echo "----------------------------------------"
lsblk | grep sd || echo "SSDが認識されていません"

echo -e "\n3. USB 3.0 接続確認"
echo "----------------------------------------"
if lsusb -t | grep -A5 "5000M"; then
    echo "✓ USB 3.0で接続されています"
else
    echo "✗ USB 3.0で接続されていない可能性があります"
fi

echo -e "\n4. SSD情報詳細"
echo "----------------------------------------"
if [ -e /dev/sda ]; then
    sudo hdparm -I /dev/sda | grep -E "Model|Serial|LBA48"
else
    echo "SSDデバイス(/dev/sda)が見つかりません"
fi

echo -e "\n5. USB電力管理確認"
echo "----------------------------------------"
for usb_device in /sys/bus/usb/devices/*/power/autosuspend; do
    if [ -f "$usb_device" ]; then
        echo "$(dirname "$usb_device" | xargs basename): $(cat "$usb_device")"
    fi
done
