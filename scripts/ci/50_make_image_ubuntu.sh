#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"
: "${UBUNTU_RELEASE:?missing UBUNTU_RELEASE}"

BUILD_EL2="${BUILD_EL2:-false}"
KREL="$(cat "$WORKDIR/kernel-release.txt")"
KREL_EL2=""
if [[ "$BUILD_EL2" == "true" && -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  KREL_EL2="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi

EFI_END_MIB=1025
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.ext4 -L rootfs "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-ubuntu
cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/run" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo mkdir -p "$MNT/boot/efi"
sudo mount "${LOOP}p1" "$MNT/boot/efi"

sudo rsync -aHAX --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' "$ROOTFS_DIR/" "$MNT/"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4   errors=remount-ro,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" KREL_EL2="$KREL_EL2" BUILD_EL2="$BUILD_EL2" /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "ubuntu" > /etc/hostname
id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%sudo ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/sudo-nopasswd
chmod 440 /etc/sudoers.d/sudo-nopasswd
cat > /etc/default/locale <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:en_US:en
LC_MESSAGES=zh_CN.UTF-8
EOF

rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/user <<'EOF'
[User]
Language=zh_CN.UTF-8
EOF
cat > /var/lib/AccountsService/users/gdm <<'EOF'
[User]
Language=zh_CN.UTF-8
SystemAccount=true
EOF

mkdir -p /home/user/.config
cat > /home/user/.config/monitors.xml <<'EOF'
<monitors version="2">
    <configuration>
        <layoutmode>logical</layoutmode>
        <logicalmonitor>
            <x>0</x>
            <y>0</y>
            <scale>1.6666666269302368</scale>
            <primary>yes</primary>
            <transform>
                <rotation>right</rotation>
                <flipped>no</flipped>
            </transform>
            <monitor>
                <monitorspec>
                    <connector>DSI-1</connector>
                    <vendor>unknown</vendor>
                    <product>unknown</product>
                    <serial>unknown</serial>
                </monitorspec>
                <mode>
                    <width>1600</width>
                    <height>2560</height>
                    <rate>60.000</rate>
                </mode>
            </monitor>
        </logicalmonitor>
    </configuration>
</monitors>
EOF
chown -R user:user /home/user

install -d -m 1777 -o root -g root /tmp/.X11-unix

cat > /etc/systemd/system/gaokun-fix-x11-unix.service <<'EOF'
[Unit]
Description=Fix /tmp/.X11-unix ownership for Xwayland
After=gdm.service
Wants=gdm.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mkdir -p /tmp/.X11-unix && chown root:root /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix'

[Install]
WantedBy=graphical.target
EOF

systemctl enable gdm NetworkManager ssh huawei-touchpad.service \
  gaokun-fix-x11-unix.service gdm-monitor-sync.service || true

mkdir -p /etc/modules-load.d
echo -e "pci-pwrctrl-pwrseq\nath11k_pci" > /etc/modules-load.d/wifi.conf
echo "btqca" > /etc/modules-load.d/bluetooth.conf
echo -e "panel-himax-hx83121a\nhimax_hx83121a_spi\nmsm\nhid_multitouch" > /etc/modules-load.d/display.conf
echo -e "lpasscc_sc8280xp\nsnd-soc-sc8280xp" > /etc/modules-load.d/audio.conf
echo -e "huawei-gaokun-ec\nhuawei-gaokun-battery\nucsi_huawei_gaokun" > /etc/modules-load.d/battery.conf

mkdir -p /etc/modprobe.d
echo "softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp" > /etc/modprobe.d/audio-deps.conf

cat >> /etc/initramfs-tools/modules <<'MODEOF'
# Storage and USB
nvme
phy-qcom-qmp-pcie
phy-qcom-qmp-combo
phy-qcom-qmp-usb
phy-qcom-snps-femto-v2
usb-storage
uas
typec
# WiFi
pci-pwrctrl-pwrseq
ath11k
ath11k_pci
# Input
i2c-hid-of
MODEOF

update-initramfs -c -k "$KREL"
if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  update-initramfs -c -k "$KREL_EL2"
fi

bootctl --esp-path=/boot/efi install
CHROOT_EOF

MACHINE_ID="$(sudo cat "$MNT/etc/machine-id")"
ENTRY_DIR="$MNT/boot/efi/loader/entries"
ESP_OS_DIR="$MNT/boot/efi/gaokun3/ubuntu"
BASE_ENTRY_FILE="${MACHINE_ID}-ubuntu-gaokun3-${KREL}.conf"
BASE_CMDLINE="root=UUID=${ROOT_UUID} clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1"

sudo mkdir -p "$ENTRY_DIR" "$ESP_OS_DIR/$KREL"
sudo install -Dm644 "$MNT/boot/vmlinuz-$KREL" "$ESP_OS_DIR/$KREL/linux"
sudo install -Dm644 "$MNT/boot/initrd.img-$KREL" "$ESP_OS_DIR/$KREL/initrd"
sudo install -Dm644 \
  "$MNT/usr/lib/linux-image-$KREL/qcom/sc8280xp-huawei-gaokun3.dtb" \
  "$ESP_OS_DIR/$KREL/sc8280xp-huawei-gaokun3.dtb"

sudo tee "$MNT/boot/efi/loader/loader.conf" >/dev/null <<EOF
default ${BASE_ENTRY_FILE}
timeout 5
console-mode keep
editor no
EOF

sudo tee "$ENTRY_DIR/$BASE_ENTRY_FILE" >/dev/null <<EOF
title Ubuntu ${UBUNTU_RELEASE}
version ${KREL}
machine-id ${MACHINE_ID}
sort-key gaokun3
architecture AA64
linux /gaokun3/ubuntu/${KREL}/linux
initrd /gaokun3/ubuntu/${KREL}/initrd
devicetree /gaokun3/ubuntu/${KREL}/sc8280xp-huawei-gaokun3.dtb
options ${BASE_CMDLINE}
EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  EL2_ENTRY_FILE="${MACHINE_ID}-ubuntu-gaokun3-${KREL_EL2}.conf"
  EL2_CMDLINE="$BASE_CMDLINE"

  sudo mkdir -p "$ESP_OS_DIR/$KREL_EL2" "$MNT/boot/efi/EFI/systemd/drivers" "$MNT/boot/efi/firmware"
  sudo install -Dm644 "$MNT/boot/vmlinuz-$KREL_EL2" "$ESP_OS_DIR/$KREL_EL2/linux"
  sudo install -Dm644 "$MNT/boot/initrd.img-$KREL_EL2" "$ESP_OS_DIR/$KREL_EL2/initrd"
  sudo install -Dm644 \
    "$MNT/usr/lib/linux-image-$KREL_EL2/qcom/sc8280xp-huawei-gaokun3-el2.dtb" \
    "$ESP_OS_DIR/$KREL_EL2/sc8280xp-huawei-gaokun3-el2.dtb"
  sudo install -Dm644 "$GAOKUN_DIR/tools/el2/slbounceaa64.efi" \
    "$MNT/boot/efi/EFI/systemd/drivers/slbounceaa64.efi"
  sudo install -Dm644 "$GAOKUN_DIR/tools/el2/qebspilaa64.efi" \
    "$MNT/boot/efi/EFI/systemd/drivers/qebspilaa64.efi"
  sudo install -Dm644 "$GAOKUN_DIR/tools/el2/tcblaunch.exe" \
    "$MNT/boot/efi/tcblaunch.exe"
  sudo install -Dm644 "$MNT/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn" \
    "$MNT/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn"
  sudo install -Dm644 "$MNT/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn" \
    "$MNT/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn"
  sudo install -Dm644 "$MNT/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn" \
    "$MNT/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn"

  sudo tee "$ENTRY_DIR/$EL2_ENTRY_FILE" >/dev/null <<EOF
title Ubuntu ${UBUNTU_RELEASE} (EL2 Hypervisor)
version ${KREL_EL2}
machine-id ${MACHINE_ID}
sort-key gaokun3-el2
architecture AA64
linux /gaokun3/ubuntu/${KREL_EL2}/linux
initrd /gaokun3/ubuntu/${KREL_EL2}/initrd
devicetree /gaokun3/ubuntu/${KREL_EL2}/sc8280xp-huawei-gaokun3-el2.dtb
options ${EL2_CMDLINE}
EOF
fi

sync

trap - EXIT
cleanup
