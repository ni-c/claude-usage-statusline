#!/usr/bin/env bash
# Builds the release assets into a directory:
#
#   scripts/stamp-release.sh 1.2.3 dist
#
# The installers get the version and the SHA-256 of the script they install baked
# in, so a release installer only ever installs the exact bytes released with it.
# SHA256SUMS covers all five assets for anyone who wants to check by hand.
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

cp "$root/install.sh" "$root/install.ps1" "$root/install.cmd" "$out/"
stamp "$out/install.sh" "^VERSION=''\$" "VERSION='$version'"
stamp "$out/install.sh" "^SHA256=''\$" "SHA256='$sh_sum'"
stamp "$out/install.ps1" "^\\\$Version = ''\$" "\$Version = '$version'"
stamp "$out/install.ps1" "^\\\$Sha256 = ''\$" "\$Sha256 = '$ps_sum'"
# install.cmd installs statusline.sh, so it carries the same checksum install.sh does.
# No $ anchor: the file is CRLF, and $ matches before the LF but after the CR, so an
# anchored pattern finds nothing. A CR-tolerant class like [[:space:]]*$ would match —
# and then the sed that shares this pattern would eat the CR and leave one lone LF line
# in an otherwise CRLF file. Unanchored is the only form that is both found and safe,
# which is why no other line in install.cmd may begin with these two assignments.
stamp "$out/install.cmd" '^set "VERSION="' "set \"VERSION=$version\""
stamp "$out/install.cmd" '^set "SHA256="' "set \"SHA256=$sh_sum\""

(cd "$out" && for f in install.cmd install.ps1 install.sh statusline.ps1 statusline.sh; do
  printf '%s  %s\n' "$(sha256_of "$f")" "$f"
done >SHA256SUMS)
