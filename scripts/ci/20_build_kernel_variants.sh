#!/usr/bin/env bash
set -euo pipefail

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${KERN_SRC:?missing KERN_SRC}"

KERN_OUT_BASE="${KERN_OUT_BASE:-$WORKDIR/kernel-out}"
KERN_OUT_EL2="${KERN_OUT_EL2:-$WORKDIR/kernel-out-el2}"
KERN_SRC_EL2="${KERN_SRC_EL2:-$WORKDIR/mainline-linux-el2}"
BUILD_EL2="${BUILD_EL2:-false}"

if [[ "$(uname -m)" == "aarch64" ]]; then
  CROSS_COMPILE="${CROSS_COMPILE:-}"
else
  CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
fi

export ARCH=arm64
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export PATH="/usr/lib/ccache:$PATH"

cleanup() {
  if [[ -d "$KERN_SRC_EL2" ]]; then
    git -C "$KERN_SRC" worktree remove --force "$KERN_SRC_EL2" 2>/dev/null || true
  fi
}
trap cleanup EXIT

configure_git_identity() {
  local repo_dir="$1"
  git -C "$repo_dir" config user.name "github-actions[bot]"
  git -C "$repo_dir" config user.email "github-actions[bot]@users.noreply.github.com"
}

build_variant() {
  local src_dir="$1"
  local out_dir="$2"
  local localversion="${3:-}"

  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  unset KCONFIG_CONFIG
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" gaokun3_defconfig

  if [[ -n "$localversion" ]]; then
    "$src_dir"/scripts/config --file "$out_dir/.config" --set-str LOCALVERSION "$localversion"
  fi

  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
  make -C "$src_dir" O="$out_dir" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" modules_prepare
}

mkdir -p "$WORKDIR"

configure_git_identity "$KERN_SRC"
git -C "$KERN_SRC" am "$GAOKUN_DIR"/patches/*.patch

build_variant "$KERN_SRC" "$KERN_OUT_BASE"
BASE_KREL="$(cat "$KERN_OUT_BASE/include/config/kernel.release")"
echo "$BASE_KREL" > "$WORKDIR/kernel-release.txt"

if [[ "$BUILD_EL2" != "true" ]]; then
  exit 0
fi

rm -rf "$KERN_SRC_EL2"
git -C "$KERN_SRC" worktree add --detach "$KERN_SRC_EL2" HEAD
configure_git_identity "$KERN_SRC_EL2"
git -C "$KERN_SRC_EL2" apply --index "$GAOKUN_DIR"/patches/el2/*.patch
git -C "$KERN_SRC_EL2" commit -m "Apply EL2 patches"

build_variant "$KERN_SRC_EL2" "$KERN_OUT_EL2" "-gaokun3-el2"
EL2_KREL="$(cat "$KERN_OUT_EL2/include/config/kernel.release")"
echo "$EL2_KREL" > "$WORKDIR/kernel-release-el2.txt"
