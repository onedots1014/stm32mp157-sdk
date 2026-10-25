#!/usr/bin/env bash
# Write the commits on top of each upstream tag in sources/<name>/ back to
# patches/<name>/ as a numbered series -- the inverse of fetch-sources.sh.
#
# Usage: scripts/export-patches.sh [linux|u-boot|tf-a|busybox|all]   (default: all)
#
# Workflow:
#   scripts/fetch-sources.sh linux        # sources/linux = tag + patches
#   cd sources/linux; edit; git commit    # or git rebase -i to reword/split
#   scripts/export-patches.sh linux       # patches/linux/ now matches
#   git add patches/linux && git commit
#
# Patches are written with --zero-commit and without a version signature, so
# re-exporting an unchanged series produces no diff.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT/sources}"
LIST="$ROOT/scripts/sources.list"

log() { printf '\033[0;34m[INFO]\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

export_one() {
  local name=$1 sha=$2
  local src="$SRC_DIR/$name" out="$ROOT/patches/$name"

  [[ -d "$src/.git" ]] || die "$name: $src is not a git tree (run scripts/fetch-sources.sh $name)"
  git -C "$src" cat-file -e "$sha^{commit}" 2>/dev/null \
    || die "$name: base commit $sha not found in $src"
  git -C "$src" merge-base --is-ancestor "$sha" HEAD \
    || die "$name: HEAD is not based on $sha (the tag in sources.list)"
  if ! git -C "$src" diff --quiet HEAD -- || [[ -n "$(git -C "$src" ls-files --others --exclude-standard | head -1)" ]]; then
    die "$name: uncommitted changes in $src -- commit them first"
  fi

  local n
  n=$(git -C "$src" rev-list --count "$sha..HEAD")
  rm -f "$out"/*.patch
  if [[ "$n" -eq 0 ]]; then
    log "$name: no commits on top of $sha, patches/$name is empty"
    rmdir "$out" 2>/dev/null || true
    return
  fi
  mkdir -p "$out"
  git -C "$src" format-patch --quiet --zero-commit --no-signature --no-numbered \
      -o "$out" "$sha..HEAD"
  log "$name: exported $n patches to patches/$name/"
}

want=${1:-all}
found=false
while read -r name url tag sha; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ "$want" == all || "$want" == "$name" ]]; then
    found=true
    if [[ "$want" == all && ! -d "$SRC_DIR/$name/.git" ]]; then
      log "$name: not fetched, skipping"
      continue
    fi
    export_one "$name" "$sha"
  fi
done < "$LIST"
$found || die "unknown component '$want' (see $LIST)"
git -C "$ROOT" status --short -- patches/
