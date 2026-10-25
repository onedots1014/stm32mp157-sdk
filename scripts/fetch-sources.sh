#!/usr/bin/env bash
# Fetch upstream sources at the exact release tags in scripts/sources.list,
# verify each tag's commit, and apply the patch series from patches/<name>/.
#
# Usage: scripts/fetch-sources.sh [linux|u-boot|tf-a|busybox|all]   (default: all)
# Output: sources/<name>/ with patches applied as git commits.
#
# To change a component: edit and commit in sources/<name>/, then run
# scripts/export-patches.sh <name> to write the series back to patches/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT/sources}"
LIST="$ROOT/scripts/sources.list"

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

  if compgen -G "$ROOT/patches/$name/*.patch" >/dev/null; then
    log "$name: applying $(ls "$ROOT/patches/$name"/*.patch | wc -l) patches"
    git -C "$dst" -c user.name="stm32mp157-sdk" -c user.email="sdk@localhost" \
        am --quiet --keep-cr "$ROOT/patches/$name"/*.patch
  else
    log "$name: no patches, using upstream as-is"
  fi
  log "$name: ready at $dst"
}

want=${1:-all}
mkdir -p "$SRC_DIR"
found=false
while read -r name url tag sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ "$want" == all || "$want" == "$name" ]]; then
    found=true
    fetch_one "$name" "$url" "$tag" "$sha"
  fi
done < "$LIST"
$found || die "unknown component '$want' (see $LIST)"
