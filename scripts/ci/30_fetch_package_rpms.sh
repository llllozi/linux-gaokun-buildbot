#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${PACKAGE_RELEASE_TAG:?missing PACKAGE_RELEASE_TAG}"
: "${PACKAGE_RPMS_DIR:?missing PACKAGE_RPMS_DIR}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
: "${GITHUB_TOKEN:?missing GITHUB_TOKEN}"

mkdir -p "$PACKAGE_RPMS_DIR"

api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${PACKAGE_RELEASE_TAG}"
release_json="$WORKDIR/package-release.json"

curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "$api_url" \
  -o "$release_json"

asset_name="package-manifest.json"
asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .url' "$release_json")"

if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
  echo "missing asset ${asset_name} in release ${PACKAGE_RELEASE_TAG}" >&2
  exit 1
fi

curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/octet-stream" \
  "$asset_url" \
  -o "$PACKAGE_RPMS_DIR/$asset_name"

manifest_path="$PACKAGE_RPMS_DIR/package-manifest.json"
manifest_kernel_tag="$(jq -r '.kernel_tag' "$manifest_path")"

if [[ "$manifest_kernel_tag" != "$KERNEL_TAG" ]]; then
  echo "package release kernel tag mismatch: expected ${KERNEL_TAG}, got ${manifest_kernel_tag}" >&2
  exit 1
fi

for asset_name in \
  "$(jq -r '.packages.kernel' "$manifest_path")" \
  "$(jq -r '.packages.kernel_modules' "$manifest_path")" \
  "$(jq -r '.packages.firmware' "$manifest_path")"; do
  asset_url="$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .url' "$release_json")"

  if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
    echo "missing asset ${asset_name} in release ${PACKAGE_RELEASE_TAG}" >&2
    exit 1
  fi

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    "$asset_url" \
    -o "$PACKAGE_RPMS_DIR/$asset_name"
done
