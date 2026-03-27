#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"

sudo mkdir -p \
  "$ROOTFS_DIR/usr/local/bin" \
  "$ROOTFS_DIR/etc/systemd/system" \
  "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-tp-activate.py" "$ROOTFS_DIR/usr/local/bin/"
sudo cp "$GAOKUN_DIR/tools/touchpad/huawei-touchpad.service" "$ROOTFS_DIR/etc/systemd/system/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/huawei-tp-activate.py"
sudo cp "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync" "$ROOTFS_DIR/usr/local/bin/"
sudo cp "$GAOKUN_DIR/tools/monitors/gdm-monitor-sync.service" \
  "$ROOTFS_DIR/etc/systemd/system/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/gdm-monitor-sync"
sudo cp "$GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py" "$ROOTFS_DIR/usr/local/bin/"
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py"
sudo cp "$GAOKUN_DIR/tools/audio/sc8280xp.conf" \
  "$ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/"
