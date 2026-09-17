#!/usr/bin/env bats
# install.cmd, run the way a release runs it: stamped by scripts/stamp-release.sh,
# with CLAUDE_STATUSLINE_SOURCE standing in for the download.
#
# These cases need cmd.exe, so they only really run on Windows, under the git-bash job.
# Everywhere else each one skips, and `bats tests/` stays green. The byte-level checks
# on install.cmd that do run everywhere live in tests/install.bats.
#
# Not ported from tests/install.bats: the symlinked settings file. A file symlink on
# Windows needs Developer Mode or elevation, and install.cmd replaces such a file
# rather than writing through it — the same as install.ps1 does.
#
# Every @test runs in its own subshell by design, so changing a variable inside
# one is meant to stay there.
# shellcheck disable=SC2030,SC2031

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  DIST="$BATS_TEST_TMPDIR/dist"
  "$ROOT/scripts/stamp-release.sh" 9.9.9 "$DIST"
  export HOME="$BATS_TEST_TMPDIR/home"
  # cmd.exe needs Windows paths; bats needs the same places as POSIX paths.
  CONFIG="$BATS_TEST_TMPDIR/config dir"
  SETTINGS="$CONFIG/settings.json"
  INSTALLED="$CONFIG/claude-usage-statusline/statusline.sh"
  # install.cmd falls back to %USERPROFILE%, which on Windows is not $HOME. Redirecting
  # it is what keeps a test out of the real profile of whoever runs the suite.
  PROFILE="$BATS_TEST_TMPDIR/profile"
  mkdir -p "$HOME" "$PROFILE"
}

needs_cmd() {
  command -v cmd.exe >/dev/null 2>&1 || skip "needs cmd.exe"
  command -v cygpath >/dev/null 2>&1 || skip "needs cygpath"
  export CLAUDE_CONFIG_DIR
  CLAUDE_CONFIG_DIR=$(cygpath -w "$CONFIG")
  export CLAUDE_STATUSLINE_SOURCE
  CLAUDE_STATUSLINE_SOURCE=$(cygpath -w "$DIST")
  export USERPROFILE
  USERPROFILE=$(cygpath -w "$PROFILE")
}

# //c so that MSYS hands cmd.exe a /c it recognises instead of rewriting it as a path.
install() {
  run cmd //c "$(cygpath -w "$DIST/install.cmd")" "$@"
}

settings_command() {
  jq -r '.statusLine.command' "$SETTINGS"
}

# Runs the configured command the way Claude Code does: through a shell, JSON on stdin.
run_configured() {
  run sh -c "$(settings_command)" <<<"$1"
}

@test "installs into an empty config directory" {
  needs_cmd
  install
  [ "$status" -eq 0 ]
  [ -f "$INSTALLED" ]
  [ "$(jq -c '.statusLine | del(.command)' "$SETTINGS")" = '{"type":"command","refreshInterval":30}' ]
  NO_COLOR=1 run_configured '{"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":12}}'
  [ "$status" -eq 0 ]
  [ "$output" = '[Opus 5] | ctx 12%' ]
}

# copy translates line endings in some of its modes, and a statusline.sh with CRLF
# does not run under bash at all.
@test "installs the exact bytes of the release" {
  needs_cmd
  install
  [ "$status" -eq 0 ]
  cmp "$DIST/statusline.sh" "$INSTALLED"
}

@test "writes a command that Git Bash runs" {
  needs_cmd
  install
  [ "$status" -eq 0 ]
  [[ "$(settings_command)" == "bash '"*"/claude-usage-statusline/statusline.sh'" ]]
}

@test "defaults to the profile without CLAUDE_CONFIG_DIR" {
  needs_cmd
  unset CLAUDE_CONFIG_DIR
  install
  [ "$status" -eq 0 ]
  [ -f "$PROFILE/.claude/claude-usage-statusline/statusline.sh" ]
}

# A ' cannot go into bash '<path>', so it is refused rather than guessed at — the same
# as install.ps1 does. install.sh escapes it instead, because it has only the one shell
# to satisfy, which is why tests/install.bats installs into "it's a dir" and this does
# not. The refusal has to come before anything is created.
@test "refuses a config directory with an apostrophe in it" {
  CONFIG="$BATS_TEST_TMPDIR/it's a dir"
  needs_cmd
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"Git Bash parses the same way"* ]]
  [ ! -e "$CONFIG/claude-usage-statusline" ]
  [ ! -e "$CONFIG/settings.json" ]
}

@test "keeps every other setting as it was" {
  needs_cmd
  mkdir -p "$CONFIG"
  cp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS"
  install
  [ "$status" -eq 0 ]
  [ "$(jq -S 'del(.statusLine)' "$SETTINGS")" = "$(jq -S . "$ROOT/tests/fixtures/settings-rich.json")" ]
  cmp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS.before-claude-usage-statusline"
}

@test "refuses to replace another status line without --force" {
  needs_cmd
  mkdir -p "$CONFIG"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh"}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"another status line is configured"* ]]
  [[ "$output" == *"~/mine.sh"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
  [ ! -e "$CONFIG/claude-usage-statusline" ]
}

@test "treats a status line without a command as someone else's" {
  needs_cmd
  mkdir -p "$CONFIG"
  printf '{"statusLine":{"type":"static"}}\n' >"$SETTINGS"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *'{"type":"static"}'* ]]
}

@test "--force replaces another status line whole" {
  needs_cmd
  mkdir -p "$CONFIG"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh","padding":4}}\n' >"$SETTINGS"
  install --force
  [ "$status" -eq 0 ]
  [ "$(jq -c '.statusLine | keys' "$SETTINGS")" = '["command","refreshInterval","type"]' ]
}

@test "reinstalling keeps refreshInterval and padding and changes nothing else" {
  needs_cmd
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
  needs_cmd
  mkdir -p "$CONFIG"
  cp "$ROOT/tests/fixtures/settings-rich.json" "$SETTINGS"
  install
  install --uninstall
  [ "$status" -eq 0 ]
  [ "$(jq -S . "$SETTINGS")" = "$(jq -S . "$ROOT/tests/fixtures/settings-rich.json")" ]
  [ ! -e "$CONFIG/claude-usage-statusline" ]
}

@test "--uninstall leaves another status line alone" {
  needs_cmd
  mkdir -p "$CONFIG"
  printf '{"statusLine":{"type":"command","command":"~/mine.sh"}}\n' >"$SETTINGS"
  cp "$SETTINGS" "$BATS_TEST_TMPDIR/before"
  install --uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"belongs to something else"* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$SETTINGS"
}

@test "--uninstall with nothing installed is a no-op" {
  needs_cmd
  install --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$SETTINGS" ]
}

# Also proves the certutil parsing works: without it there would be no verdict to give.
@test "refuses a script that does not match the release checksum" {
  needs_cmd
  printf '\n# tampered\n' >>"$DIST/statusline.sh"
  install
  [ "$status" -eq 1 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [ ! -e "$SETTINGS" ]
  [ ! -e "$CONFIG/claude-usage-statusline" ]
}

@test "refuses a settings file that is not a JSON object" {
  needs_cmd
  mkdir -p "$CONFIG"
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

@test "an installer from a checkout refuses to download" {
  needs_cmd
  unset CLAUDE_STATUSLINE_SOURCE
  run cmd //c "$(cygpath -w "$ROOT/install.cmd")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not belong to a release"* ]]
}

@test "rejects unknown options" {
  needs_cmd
  install --frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

# System32 has curl.exe and certutil.exe but no jq.exe, so this hits the jq branch
# and nothing else.
@test "says what to do when jq is missing" {
  needs_cmd
  run env PATH="$(cygpath -u 'C:\Windows\System32')" cmd //c "$(cygpath -w "$DIST/install.cmd")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"jq is required"* ]]
}
