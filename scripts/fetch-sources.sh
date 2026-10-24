#!/usr/bin/env bash
# Fetch ST vendor sources at the exact release tags this SDK is based on,
# verify the tag commits, and apply the board patch series on top.
#
# Usage: scripts/fetch-sources.sh [linux|u-boot|tf-a|all]   (default: all)
# Output: sources/<component>/ with patches applied as git commits.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT/sources}"

#  component  repo                                                      tag                      expected commit
COMPONENTS=(
  "linux  https://github.com/STMicroelectronics/linux.git                v5.4-stm32mp-r2.4      c60f477af944f846e85dc7f066c101eba0005b9f"
  "u-boot https://github.com/STMicroelectronics/u-boot.git               v2020.01-stm32mp-r2.2  d543131c5835b2ca010d8169a06dbca3014355fd"
  "tf-a   https://github.com/STMicroelectronics/arm-trusted-firmware.git v2.10-stm32mp-r3       41575b25c972b6f8958c101458d06ed23e38442b"
)

log() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

fetch_one() {
  local name=$1 url=$2 tag=$3 sha=$4
  local dst="$SRC_DIR/$name"

  if [[ -d "$dst/.git" ]]; then
    log "$name: $dst already exists, skipping (delete it to re-fetch)"
    return
  fi

  log "$name: cloning $tag (shallow)"
  git clone --quiet --depth 1 --branch "$tag" "$url" "$dst"

  local got
  got=$(git -C "$dst" rev-parse HEAD)
  [[ "$got" == "$sha" ]] || die "$name: tag $tag resolved to $got, expected $sha"

  log "$name: applying $(ls "$ROOT/patches/$name"/*.patch | wc -l) patches"
  git -C "$dst" -c user.name="stm32mp157-sdk" -c user.email="sdk@localhost" \
      am --quiet --keep-cr "$ROOT/patches/$name"/*.patch
  log "$name: ready at $dst"
}

want=${1:-all}
mkdir -p "$SRC_DIR"
for entry in "${COMPONENTS[@]}"; do
  read -r name url tag sha <<<"$entry"
  if [[ "$want" == all || "$want" == "$name" ]]; then
    fetch_one "$name" "$url" "$tag" "$sha"
  fi
done
