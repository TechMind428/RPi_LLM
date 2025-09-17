#!/bin/bash
echo ">>> PCIe有効化設定..."

# config.txtにPCIe設定追加
if ! grep -q "dtparam=pciex1" /boot/firmware/config.txt; then
    echo "dtparam=pciex1" | sudo tee -a /boot/firmware/config.txt
fi

if ! grep -q "dtparam=pciex1_gen=3" /boot/firmware/config.txt; then
    echo "dtparam=pciex1_gen=3" | sudo tee -a /boot/firmware/config.txt
fi

# NVMeドライバーの確実な読み込み設定
echo ">>> NVMeドライバー設定..."
if ! grep -q "^nvme$" /etc/modules; then
    echo "nvme" | sudo tee -a /etc/modules
fi

# initramfs更新
sudo update-initramfs -u

echo ">>> 設定完了。再起動が必要です。"
echo ">>> sudo reboot で再起動してください"
