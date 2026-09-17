#!/usr/bin/env bats
# install.sh, run the way a release runs it: stamped by scripts/stamp-release.sh,
# with CLAUDE_STATUSLINE_SOURCE standing in for the download.
#
# Every @test runs in its own subshell by design, so changing a variable inside
# one is meant to stay there.
# shellcheck disable=SC2030,SC2031

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DIST="$BATS_TEST_TMPDIR/dist"
  "$ROOT/scripts/stamp-release.sh" 9.9.9 "$DIST"
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/config dir"
  export CLAUDE_STATUSLINE_SOURCE="$DIST"
  SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
  mkdir -p "$HOME"
}

install() {
  run "${STATUSLINE_BASH:-bash}" "$DIST/install.sh" "$@"
}

settings_command() {
  jq -r '.statusLine.command' "$SETTINGS"
}

# Runs the configured command the way Claude Code does: through a shell, JSON on stdin.
run_configured() {
  run sh -c "$(settings_command)" <<<"$1"
}

@test "installs into an empty config directory" {
  install
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_CONFIG_DIR/claude-usage-statusline/statusline.sh" ]
  [ "$(jq -c '.statusLine | del(.command)' "$SETTINGS")" = '{"type":"command","refreshInterval":30}' ]
  NO_COLOR=1 run_configured '{"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":12}}'
  [ "$status" -eq 0 ]
  [ "$output" = '[Opus 5] | ctx 12%' ]
}

@test "installs the exact bytes of the release" {
  install
  cmp "$DIST/statusline.sh" "$CLAUDE_CONFIG_DIR/claude-usage-statusline/statusline.sh"
}

@test "defaults to ~/.claude without CLAUDE_CONFIG_DIR" {
  unset CLAUDE_CONFIG_DIR
  install
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/claude-usage-statusline/statusline.sh" ]
  [ "$(jq -r .statusLine.command "$HOME/.claude/settings.json")" = "bash $HOME/.claude/claude-usage-statusline/statusline.sh" ]
}

@test "quotes a config directory with spaces and quotes in it" {
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/it's a dir"
  SETTINGS="$CLAUDE_CONFIG_DIR/settings.json"
  install
  [ "$status" -eq 0 ]
  NO_COLOR=1 run_configured '{"model":{"display_name":"q"}}'
  [ "$output" = '[q]' ]
}

@test "keeps every other setting as it was" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS"
  install
  [ "$status" -eq 0 ]
  [ "$(jq -S 'del(.statusLine)' "$SETTINGS")" = "$(jq -S . "$ROOT/tests/fixtures/settings-rich.json")" ]
  cmp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS.before-claude-usage-statusline"
}

@test "refuses to replace another status line without --force" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh"}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"another status line is configured"* ]]
  [[ "$output" == *"~/mine.sh"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
  [ ! -e "$CLAUDE_CONFIG_DIR/claude-usage-statusline" ]
}

@test "treats a status line without a command as someone else's" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"statusLine":{"type":"static"}}\n' >"$SETTINGS"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"type":"static"}'* ]]
}

@test "--force replaces another status line whole" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh","padding":4}}\n' >"$SETTINGS"
  install --force
  [ "$status" -eq 0 ]
  [ "$(jq -c '.statusLine | keys' "$SETTINGS")" = '["command","refreshInterval","type"]' ]
  [[ "$(settings_command)" == *"claude-usage-statusline/statusline.sh'" ]]
}

@test "reinstalling keeps refreshInterval and padding and changes nothing else" {
  install
  jq '.statusLine.refreshInterval = 5 | .statusLine.padding = 2' "$SETTINGS" >"$SETTINGS.new"
  mv "$SETTINGS.new" "$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
  [[ "$output" != *"Previous settings saved"* ]]
}

@test "--uninstall removes its entry and files and keeps the rest" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  cp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS"
  install
  install --uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -S . "$SETTINGS")" = "$(jq -S . "$ROOT/tests/fixtures/settings-rich.json")" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/claude-usage-statusline" ]
}

@test "--uninstall leaves another status line alone" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh"}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"belongs to something else"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
}

@test "--uninstall with nothing installed is a no-op" {
  install --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SETTINGS" ]
}

@test "refuses a script that does not match the release checksum" {
  printf '\n# tampered\n' >>"$DIST/statusline.sh"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$SETTINGS" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/claude-usage-statusline" ]
}

@test "refuses a settings file that is not a JSON object" {
  mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"model": "opus",\n// a comment\n}\n' >"$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a JSON object"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
  printf '[1]\n' >"$SETTINGS"
  install
  [ "$status" -eq 1 ]
}

@test "writes through a symlinked settings file" {
  mkdir -p "$CLAUDE_CONFIG_DIR" "$BATS_TEST_TMPDIR/dotfiles"
  printf '{"model":"opus"}\n' >"$BATS_TEST_TMPDIR/dotfiles/settings.json"
  ln -s "$BATS_TEST_TMPDIR/dotfiles/settings.json" "$SETTINGS"
  install
  [ "$status" -eq 0 ]
  [ -L "$SETTINGS" ]
  [ "$(jq -r .model "$BATS_TEST_TMPDIR/dotfiles/settings.json")" = opus ]
  [ "$(jq -r .statusLine.type "$BATS_TEST_TMPDIR/dotfiles/settings.json")" = command ]
}

@test "an installer from a checkout refuses to download" {
  unset CLAUDE_STATUSLINE_SOURCE
  run bash "$ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not belong to a release"* ]]
}

@test "rejects unknown options" {
  install --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "says what to do when jq is missing" {
  local p="$BATS_TEST_TMPDIR/bin" cmd
  mkdir -p "$p"
  for cmd in bash cat cp mkdir dirname uname; do ln -s "$(command -v "$cmd")" "$p/$cmd"; done
  run env PATH="$p" bash "$DIST/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is required"* ]]
}

@test "stamp-release refuses a malformed version" {
  run "$ROOT/scripts/stamp-release.sh" v1.0 "$BATS_TEST_TMPDIR/x"
  [ "$status" -eq 2 ]
}

@test "stamp-release bakes version and checksums into all three installers" {
  grep -qx "VERSION='9.9.9'" "$DIST/install.sh"
  grep -qx "\$Version = '9.9.9'" "$DIST/install.ps1"
  local sh_sum ps_sum
  sh_sum=$(grep '  statusline.sh$' "$DIST/SHA256SUMS" | cut -d' ' -f1)
  ps_sum=$(grep '  statusline.ps1$' "$DIST/SHA256SUMS" | cut -d' ' -f1)
  grep -qx "SHA256='$sh_sum'" "$DIST/install.sh"
  grep -qx "\$Sha256 = '$ps_sum'" "$DIST/install.ps1"
  # install.cmd installs statusline.sh, so it carries install.sh's checksum, not the
  # PowerShell one. The CR has to come off first: -x anchors at the end of the line,
  # and the CR is part of it.
  tr -d '\r' <"$DIST/install.cmd" | grep -qx 'set "VERSION=9.9.9"'
  tr -d '\r' <"$DIST/install.cmd" | grep -qx "set \"SHA256=$sh_sum\""
  [ "$(wc -l <"$DIST/SHA256SUMS")" -eq 5 ]
}

# The bytes of install.cmd are load-bearing twice over: cmd.exe is unreliable on
# LF-only line endings and reads the file in the OEM code page, and stamp-release.sh
# substitutes into it with a pattern that a "helpful" [[:space:]]*$ would break by
# eating the CR of exactly that one line. Both the source and the stamped copy.
@test "install.cmd is CRLF and plain ASCII" {
  local f crs lfs
  for f in "$ROOT/install.cmd" "$DIST/install.cmd"; do
    crs=$(LC_ALL=C tr -cd '\r' <"$f" | wc -c)
    lfs=$(LC_ALL=C tr -cd '\n' <"$f" | wc -c)
    [ "$crs" -eq "$lfs" ]
    ! LC_ALL=C grep -q $'\r\r' "$f"
    [ -z "$(LC_ALL=C tr -d '\015\012\040-\176' <"$f")" ]
  done
}

# Nothing lints batch, so the handful of structural rules that actually bite are
# assertions instead. The placeholder counts front-run a stamp-release failure from
# tag time to the pull request.
@test "install.cmd keeps the shape stamp-release and cmd.exe expect" {
  local body
  body=$(tr -d '\r' <"$ROOT/install.cmd")
  [ "$(printf '%s\n' "$body" | head -1)" = '@echo off' ]
  printf '%s\n' "$body" | grep -q '^setlocal '
  [ "$(printf '%s\n' "$body" | grep -c '^set "VERSION="')" -eq 1 ]
  [ "$(printf '%s\n' "$body" | grep -c '^set "SHA256="')" -eq 1 ]
  [ -z "$(LC_ALL=C tr -cd '\011' <"$ROOT/install.cmd")" ]
  [ "$(tail -c 1 "$ROOT/install.cmd" | od -An -tx1 | tr -d ' \n')" = '0a' ]
}
