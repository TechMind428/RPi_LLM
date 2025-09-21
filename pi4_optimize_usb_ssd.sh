#!/bin/bash
echo "=========================================="
echo " USB SSD 最適化設定"
echo "=========================================="

# USB自動サスペンド無効化
echo ">>> USB自動サスペンド無効化..."
echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="152d", ATTR{power/autosuspend}="-1"' | \
    sudo tee /etc/udev/rules.d/50-usb-ssd.rules

# USB電力管理設定
echo ">>> USB電力管理最適化..."
if ! grep -q "usbcore.autosuspend" /boot/cmdline.txt; then
    sudo sed -i '$ s/$/ usbcore.autosuspend=-1/' /boot/cmdline.txt
fi

# ファイルシステム最適化設定
echo ">>> ファイルシステム最適化設定..."
echo 'vm.dirty_ratio=5' | sudo tee -a /etc/sysctl.conf
echo 'vm.dirty_background_ratio=2' | sudo tee -a /etc/sysctl.conf

# UAS（USB Attached SCSI）最適化
echo ">>> UAS最適化設定..."
if ! grep -q "usb-storage.quirks" /boot/cmdline.txt; then
    sudo sed -i '$ s/$/ usb-storage.quirks=152d:0578:u/' /boot/cmdline.txt
fi

echo "✓ USB SSD最適化設定完了"
echo "再起動が推奨されます: sudo reboot"
