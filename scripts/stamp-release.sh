#!/usr/bin/env bash
# Builds the release assets into a directory:
#
#   scripts/stamp-release.sh 1.2.3 dist
#
# The installers get the version and the SHA-256 of the script they install baked
# in, so a release installer only ever installs the exact bytes released with it.
# SHA256SUMS covers all four assets for anyone who wants to check by hand.
set -euo pipefail

version=${1:?usage: stamp-release.sh VERSION OUTDIR}
out=${2:?usage: stamp-release.sh VERSION OUTDIR}
root=$(cd "$(dirname "$0")/.." && pwd)

case "$version" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "not a version: $version" >&2; exit 2 ;;
esac

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

mkdir -p "$out"
cp "$root/statusline.sh" "$root/statusline.ps1" "$out/"
sh_sum=$(sha256_of "$out/statusline.sh")
ps_sum=$(sha256_of "$out/statusline.ps1")

# stamp FILE PATTERN REPLACEMENT — exactly one line must match, or the build fails.
stamp() {
  local count
  count=$(grep -c "$2" "$1" || true)
  [ "$count" = 1 ] || { echo "$1: expected one line matching '$2', found $count" >&2; exit 1; }
  sed "s|$2|$3|" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

cp "$root/install.sh" "$root/install.ps1" "$out/"
stamp "$out/install.sh" "^VERSION=''\$" "VERSION='$version'"
stamp "$out/install.sh" "^SHA256=''\$" "SHA256='$sh_sum'"
stamp "$out/install.ps1" "^\\\$Version = ''\$" "\$Version = '$version'"
stamp "$out/install.ps1" "^\\\$Sha256 = ''\$" "\$Sha256 = '$ps_sum'"

(cd "$out" && for f in install.ps1 install.sh statusline.ps1 statusline.sh; do
  printf '%s  %s\n' "$(sha256_of "$f")" "$f"
done >SHA256SUMS)
