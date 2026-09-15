#!/usr/bin/env bash
# Installs claude-usage-statusline as the Claude Code status line (Linux, macOS, WSL).
#
#   curl -fsSL https://github.com/ni-c/claude-usage-statusline/releases/latest/download/install.sh | bash
#   … | bash -s -- --force        replace a status line that is already configured
#   … | bash -s -- --uninstall    remove it again
#
# What it does: downloads statusline.sh from the release this installer belongs to,
# checks it against the SHA-256 baked in below, puts it in
# ~/.claude/claude-usage-statusline/ and sets `statusLine` in ~/.claude/settings.json.
# Every other setting is left as it is. CLAUDE_CONFIG_DIR is respected.

set -euo pipefail

REPO='ni-c/claude-usage-statusline'
# Stamped by scripts/stamp-release.sh when a release is built. An installer taken
# from a checkout has neither and installs only from CLAUDE_STATUSLINE_SOURCE.
VERSION=''
SHA256=''

NAME='claude-usage-statusline'
# How an installed status line is recognised as ours, on either OS.
MARKER="$NAME/statusline."

die() {
  printf '%s: %s\n' "$NAME" "$1" >&2
  exit "${2:-1}"
}

info() {
  printf '%s\n' "$1"
}

usage() {
  cat <<EOF
Usage: install.sh [--force] [--uninstall]

  --force       replace a status line that another tool configured
  --uninstall   remove claude-usage-statusline and its settings entry
EOF
}

FORCE=0 UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" 2 ;;
  esac
done

CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
INSTALL_DIR="$CONFIG_DIR/$NAME"
TARGET="$INSTALL_DIR/statusline.sh"
SETTINGS="$CONFIG_DIR/settings.json"

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required, both here and by the status line itself.
  Debian/Ubuntu: sudo apt install jq    Fedora: sudo dnf install jq    Arch: sudo pacman -S jq
  macOS: brew install jq                Windows: use install.ps1 instead, it needs nothing"
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    openssl dgst -sha256 "$1" | sed 's/.*= //'
  fi
}

# Single-quoted for sh when the path needs it, so a config dir with spaces works.
shell_quote() {
  case "$1" in
    *[!A-Za-z0-9_./-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The settings file as JSON, or {} when there is none yet. Refuses anything that is
# not a JSON object instead of guessing, before anything has been touched.
read_settings() {
  if [ ! -e "$SETTINGS" ]; then
    printf '{}'
    return
  fi
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 ||
    die "$SETTINGS is not a JSON object. Fix it first; nothing was changed."
  cat "$SETTINGS"
}

# Replaces the settings file with $1. Written to a temporary file next to it and
# moved into place, so an interrupted run never leaves half a file. A copy of the
# previous version is kept next to it. A symlinked settings file (dotfile managers)
# is written through, not replaced by a regular file.
write_settings() {
  local tmp="$SETTINGS.tmp.$$" backup=''
  mkdir -p "$CONFIG_DIR"
  if [ -e "$SETTINGS" ]; then
    if printf '%s\n' "$1" | cmp -s - "$SETTINGS"; then
      return
    fi
    backup="$SETTINGS.before-$NAME"
    cp -p "$SETTINGS" "$backup"
    cp -p "$SETTINGS" "$tmp"
  fi
  printf '%s\n' "$1" >"$tmp"
  if [ -L "$SETTINGS" ]; then
    cat "$tmp" >"$SETTINGS"
    rm -f "$tmp"
  else
    mv -f "$tmp" "$SETTINGS"
  fi
  [ -z "$backup" ] || info "Previous settings saved as $backup"
}

# The configured status line command, "" when there is none, or the entry as JSON
# when it has no command at all — which still is not ours to overwrite. The CR
# comes from a native jq.exe under Git Bash.
current_command() {
  printf '%s' "$1" | jq -r '.statusLine
    | if . == null then "" elif type == "object" and .command != null then (.command | tostring) else tojson end' |
    tr -d '\r'
}

if [ "$UNINSTALL" -eq 1 ]; then
  settings=$(read_settings)
  cmd=$(current_command "$settings")
  case "$cmd" in
    *"$MARKER"*)
      write_settings "$(printf '%s' "$settings" | jq 'del(.statusLine)')"
      info "Removed the statusLine entry from $SETTINGS"
      ;;
    '') ;;
    *) info "Left the statusLine entry alone, it belongs to something else: $cmd" ;;
  esac
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    info "Removed $INSTALL_DIR"
  fi
  exit 0
fi

settings=$(read_settings)
cmd=$(current_command "$settings")
case "$cmd" in
  '' | *"$MARKER"*) ;;
  *)
    [ "$FORCE" -eq 1 ] ||
      die "another status line is configured in $SETTINGS:
  $cmd
Re-run with --force to replace it (the old entry is kept in $SETTINGS.before-$NAME)."
    ;;
esac

case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*)
    info "Note: on Windows, install.ps1 is the better choice. This installs the bash
version, which needs jq on the PATH of Git Bash every time the status line runs."
    ;;
esac

tmp_script="$(mktemp "${TMPDIR:-/tmp}/$NAME.XXXXXX")"
trap 'rm -f "$tmp_script"' EXIT

if [ -n "${CLAUDE_STATUSLINE_SOURCE:-}" ]; then
  cp "$CLAUDE_STATUSLINE_SOURCE/statusline.sh" "$tmp_script"
elif [ -z "$VERSION" ]; then
  die "this installer does not belong to a release. Use the one-liner from the README,
or set CLAUDE_STATUSLINE_SOURCE to a checkout to install from there."
else
  url="https://github.com/$REPO/releases/download/v$VERSION/statusline.sh"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp_script" "$url" || die "download failed: $url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$tmp_script" "$url" || die "download failed: $url"
  else
    die "curl or wget is required to download $url"
  fi
fi

if [ -n "$SHA256" ]; then
  actual=$(sha256_of "$tmp_script")
  [ "$actual" = "$SHA256" ] ||
    die "checksum mismatch for statusline.sh: expected $SHA256, got $actual. Nothing was changed."
fi

mkdir -p "$INSTALL_DIR"
cp "$tmp_script" "$TARGET"
chmod 755 "$TARGET"

command="bash $(shell_quote "$TARGET")"
# Keeps refreshInterval and padding from an earlier installation of ours; a
# foreign entry is replaced whole. refreshInterval keeps the countdown moving
# while Claude Code is idle.
new_settings=$(printf '%s' "$settings" | jq --arg cmd "$command" --arg marker "$MARKER" '
  (if ((.statusLine.command // "") | tostring | contains($marker)) then .statusLine else {} end) as $old
  | .statusLine = ($old + {type: "command", command: $cmd})
  | .statusLine.refreshInterval //= 30')
write_settings "$new_settings"

# Proves the installed line runs here, with this jq, before claiming success.
probe=$(printf '{"model":{"display_name":"ok"}}' |
  env -u CLAUDE_STATUSLINE_SEGMENTS NO_COLOR=1 bash "$TARGET" 2>&1) || true
[ "$probe" = '[ok]' ] || die "installed, but a test run printed: $probe"

info "Installed $NAME${VERSION:+ $VERSION} to $TARGET"
info "Claude Code picks up the new status line within a few seconds; restart it if not."
