#!/usr/bin/env bash
# Download the vendor firmware listed in scripts/firmware.list into
# sources/firmware/<install path>, verifying each file's SHA256.
# build_script/busybox/build.sh copies sources/firmware/ into the rootfs.
#
# Usage: scripts/fetch-firmware.sh
#
# To use your own copy of a file instead (for example a firmware version you
# have already tested), put it in a directory and point LOCAL_FIRMWARE_DIR at
# it; files found there by name are used as-is, without the checksum:
#   LOCAL_FIRMWARE_DIR=~/my-fw scripts/fetch-firmware.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT/sources}"
OUT="$SRC_DIR/firmware"
LIST="$ROOT/scripts/firmware.list"

log()  { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v sha256sum >/dev/null || die "sha256sum not found"

while read -r name dest sha url; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  out="$OUT/$dest"
  mkdir -p "$(dirname "$out")"

  if [[ -n "${LOCAL_FIRMWARE_DIR:-}" && -f "$LOCAL_FIRMWARE_DIR/$name" ]]; then
    cp "$LOCAL_FIRMWARE_DIR/$name" "$out"
    warn "$name: using local copy $LOCAL_FIRMWARE_DIR/$name (sha256 $(sha256sum "$out" | cut -c1-16)..., not the pinned version)"
    continue
  fi

  if [[ -f "$out" ]] && echo "$sha  $out" | sha256sum -c --status; then
    log "$name: already present and verified"
    continue
  fi

  log "$name: downloading"
  tmp="$out.part"
  curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "$name: download failed from $url"; }
  if ! echo "$sha  $tmp" | sha256sum -c --status; then
    got=$(sha256sum "$tmp" | cut -d' ' -f1)
    rm -f "$tmp"
    die "$name: sha256 mismatch (got $got, expected $sha)"
  fi
  mv "$tmp" "$out"
  log "$name: verified, installed as $dest"
done < "$LIST"
