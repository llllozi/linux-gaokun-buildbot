#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${PACKAGE_PACMAN_DIR:?missing PACKAGE_PACMAN_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"
: "${ARCH_MIRROR_URL:?missing ARCH_MIRROR_URL}"

BUILD_EL2="${BUILD_EL2:-false}"
DESKTOP_ENVIRONMENT="${DESKTOP_ENVIRONMENT:-gnome gdm}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
KREL_EL2=""
if [[ "$BUILD_EL2" == "true" && -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  KREL_EL2="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi

EFI_END_MIB=301
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

MNT=/mnt/ego-arch
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

sudo rsync -aHAX "$ROOTFS_DIR/" "$MNT/"
install_common_image_assets "$MNT" "$GAOKUN_DIR"
sudo rm -f "$MNT/etc/resolv.conf"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4  errors=remount-ro,noatime  0  1
UUID=${EFI_UUID}   /boot/efi vfat  defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mkdir -p "$MNT/tmp/gaokun-pkgs"
sudo cp "$PACKAGE_PACMAN_DIR"/*.pkg.tar.zst "$MNT/tmp/gaokun-pkgs/"

if [[ "$(uname -m)" != "aarch64" ]]; then
  sudo cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/qemu-aarch64-static"
fi

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env \
  KREL="$KREL" \
  KREL_EL2="$KREL_EL2" \
  BUILD_EL2="$BUILD_EL2" \
  ROOT_UUID="$ROOT_UUID" \
  DESKTOP_ENVIRONMENT="$DESKTOP_ENVIRONMENT" \
  EXTRA_PACKAGES="$EXTRA_PACKAGES" \
  ARCH_MIRROR_URL="$ARCH_MIRROR_URL" \
  /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "arch-gaokun3" > /etc/hostname

sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 4/' /etc/pacman.conf
sed -i 's/^DownloadUser = .*/DownloadUser = root/' /etc/pacman.conf || true
sed -i 's/^#DisableSandboxFilesystem/DisableSandboxFilesystem/' /etc/pacman.conf || true
sed -i 's/^#DisableSandboxSyscalls/DisableSandboxSyscalls/' /etc/pacman.conf || true
printf 'Server = %s/$arch/$repo\n' "$ARCH_MIRROR_URL" > /etc/pacman.d/mirrorlist

pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm

pacman -Rdd --noconfirm linux-aarch64 linux-aarch64-headers linux-firmware \
  linux-firmware-atheros linux-firmware-qcom || true
rm -rf /usr/lib/firmware/*

pacman -U --noconfirm /tmp/gaokun-pkgs/*.pkg.tar.zst

pacman -S --noconfirm --needed \
  base sudo networkmanager openssh grub efibootmgr mkinitcpio \
  wireless-regdb iwd btrfs-progs alsa-utils pipewire pipewire-alsa \
  noto-fonts noto-fonts-cjk noto-fonts-emoji \
  ${DESKTOP_ENVIRONMENT} ${EXTRA_PACKAGES}

id -u user >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel user
echo "user:user" | chpasswd
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/wheel-nopasswd
chmod 440 /etc/sudoers.d/wheel-nopasswd

cat > /etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=solar24x32
EOF

cat > /etc/locale.gen <<'EOF'
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
EOF
locale-gen
cat > /etc/locale.conf <<'EOF'
LANG=zh_CN.UTF-8
LC_MESSAGES=zh_CN.UTF-8
EOF

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

install -d -m 0755 /home/user/.config
install -Dm644 /usr/local/share/gaokun/monitors.xml /home/user/.config/monitors.xml
chown -R user:user /home/user

mkdir -p /etc/mkinitcpio.conf.d
cat > /etc/mkinitcpio.conf.d/gaokun3.conf <<'EOF'
MODULES=(nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of)
BINARIES=()
FILES=(/usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /usr/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin)
HOOKS=(base udev autodetect modconf kms keyboard keymap block filesystems fsck)
EOF

mkinitcpio -k "$KREL" -g /boot/initramfs-linux-gaokun3.img
if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  mkinitcpio -k "$KREL_EL2" -g /boot/initramfs-linux-gaokun3-el2.img
fi

systemctl enable NetworkManager sshd huawei-touchpad.service \
  gdm-monitor-sync.service patch-nvm-bdaddr.service \
  gaokun-wifi-mac@wlP6p1s0.service || true
systemctl enable gdm.service || true

grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=arch --no-nvram --recheck
mkdir -p /boot/efi/EFI/Boot
cp /boot/efi/EFI/arch/grubaa64.efi /boot/efi/EFI/Boot/BOOTAA64.EFI

BASE_CMDLINE="root=UUID=${ROOT_UUID} rw clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1"

mkdir -p /boot/grub
cat > /boot/grub/grub.cfg <<EOF
set timeout=5
set default=0

menuentry "Arch Linux ARM gaokun3" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    devicetree /boot/dtbs/linux-gaokun3/qcom/sc8280xp-huawei-gaokun3.dtb
    linux /boot/vmlinuz-linux-gaokun3 ${BASE_CMDLINE}
    initrd /boot/initramfs-linux-gaokun3.img
}
EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  cat >> /boot/grub/grub.cfg <<EOF

menuentry "Arch Linux ARM gaokun3 EL2" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    devicetree /boot/dtbs/linux-gaokun3-el2/qcom/sc8280xp-huawei-gaokun3-el2.dtb
    linux /boot/vmlinuz-linux-gaokun3-el2 ${BASE_CMDLINE} modprobe.blacklist=simpledrm
    initrd /boot/initramfs-linux-gaokun3-el2.img
}
EOF
fi

rm -f /etc/machine-id
systemd-machine-id-setup
cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
rm -rf /tmp/gaokun-pkgs
pacman -Scc --noconfirm || true
CHROOT_EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  install_el2_efi_payloads "$MNT" "$GAOKUN_DIR"
fi

sudo rm -f "$MNT/usr/bin/qemu-aarch64-static"

sync

trap - EXIT
cleanup
