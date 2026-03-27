#!/usr/bin/env bash
set -euo pipefail

: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${PACKAGE_RPMS_DIR:?missing PACKAGE_RPMS_DIR}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"

manifest_path="$PACKAGE_RPMS_DIR/package-manifest.json"
manifest_kernel_release="$(jq -r '.kernel_release' "$manifest_path")"
kernel_rpm_name="$(jq -r '.packages.kernel' "$manifest_path")"
kernel_modules_rpm_name="$(jq -r '.packages.kernel_modules' "$manifest_path")"
firmware_rpm_name="$(jq -r '.packages.firmware' "$manifest_path")"
echo "$manifest_kernel_release" > "$WORKDIR/kernel-release.txt"

sudo docker run --rm \
  -v "$(dirname "$ROOTFS_DIR")":"$(dirname "$ROOTFS_DIR")" \
  -v "$PACKAGE_RPMS_DIR":"$PACKAGE_RPMS_DIR" \
  -w / \
  --user root \
  "fedora:${FEDORA_RELEASE}" \
  bash -euxo pipefail -c '
    dnf -y --installroot="'"$ROOTFS_DIR"'" --releasever="'"$FEDORA_RELEASE"'" --use-host-config --nogpgcheck \
      install \
      "'"$PACKAGE_RPMS_DIR"'/'"$kernel_rpm_name"'" \
      "'"$PACKAGE_RPMS_DIR"'/'"$kernel_modules_rpm_name"'" \
      "'"$PACKAGE_RPMS_DIR"'/'"$firmware_rpm_name"'"
  '

sudo depmod -b "$ROOTFS_DIR" -a "$manifest_kernel_release"
