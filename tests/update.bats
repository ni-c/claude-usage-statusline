#!/usr/bin/env bats
# The update segment of statusline.sh, run as a release runs it: stamped by
# scripts/stamp-release.sh as 1.1.0. curl is a fake that logs its arguments and
# answers with $FAKE_CURL_REDIRECT, so nothing here reaches the network.

# REDIRECT is set per test, and bats runs every test in a subshell of its own.
# shellcheck disable=SC2030,SC2031

ESC=$'\033'
TAG_URL=https://github.com/ni-c/claude-usage-statusline/releases/tag

setup_file() {
  export ROOT="$BATS_TEST_DIRNAME/.."
  export WORK="$BATS_FILE_TMPDIR"
  "$ROOT/scripts/stamp-release.sh" 1.1.0 "$WORK/dist" >/dev/null
  export SCRIPT="$WORK/dist/statusline.sh"
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/curl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
[ -n "${FAKE_CURL_SLEEP:-}" ] && sleep "$FAKE_CURL_SLEEP"
printf '%s' "$FAKE_CURL_REDIRECT"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$WORK/bin/curl"
}

setup() {
  export CACHE="$BATS_TEST_TMPDIR/cache"
  export LOG="$BATS_TEST_TMPDIR/curl.log"
  export REDIRECT="$TAG_URL/v1.2.0"
}

# render [KEY=VALUE…] → runs the stamped script at NOW=1800000000 with the model and
# update segments; the assignments are added to (or override) that environment.
render() {
  run env -u CLAUDE_STATUSLINE_UPDATE_CHECK -u CLAUDE_STATUSLINE_NO_EMOJI \
    -u CLAUDE_STATUSLINE_SHORT_MODEL -u CLAUDE_STATUSLINE_EFFORT \
    -u DO_NOT_TRACK -u CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -u XDG_CACHE_HOME \
    PATH="$WORK/bin:$PATH" NO_COLOR=1 CLAUDE_STATUSLINE_NOW=1800000000 \
    CLAUDE_STATUSLINE_CACHE_DIR="$CACHE" CLAUDE_STATUSLINE_SEGMENTS=model,update \
    FAKE_CURL_LOG="$LOG" FAKE_CURL_REDIRECT="$REDIRECT" "$@" \
    "${STATUSLINE_BASH:-bash}" "${SCRIPT_UNDER_TEST:-$SCRIPT}" <<<'{"model":{"display_name":"M"}}'
}

seed() {
  mkdir -p "$CACHE"
  printf '%s\n' "$1" >"$CACHE/latest"
}

cache() { cat "$CACHE/latest"; }

calls() { if [ -f "$LOG" ]; then wc -l <"$LOG" | tr -d ' '; else echo 0; fi; }

# The fetch runs in the background: wait for its result, five seconds at most.
wait_for_cache() {
  local tries=0
  while [ "$tries" -lt 50 ]; do
    [ "$(cache 2>/dev/null)" = "$1" ] && return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  echo "cache is '$(cache 2>/dev/null)', expected '$1'" >&2
  return 1
}

# Long enough for a background fetch that should not happen to have happened.
settle() { sleep 0.5; }

# wait_for_calls N → until curl has been called N times, then a moment for the rest
# of that fetch to finish.
wait_for_calls() {
  local tries=0
  while [ "$tries" -lt 50 ]; do
    [ "$(calls)" = "$1" ] && { settle; return 0; }
    sleep 0.1
    tries=$((tries + 1))
  done
  echo "curl was called $(calls) times, expected $1" >&2
  return 1
}

@test "a copy from a checkout is not stamped and never checks" {
  SCRIPT_UNDER_TEST="$ROOT/statusline.sh" render
  [ "$status" -eq 0 ]
  [ "$output" = '[M]' ]
  settle
  [ ! -e "$CACHE" ]
  [ "$(calls)" = 0 ]
}

@test "a newer release in a fresh cache shows, and nothing is fetched" {
  seed '1799999000 1.2.0'
  render
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
  settle
  [ "$(calls)" = 0 ]
  [ "$(cache)" = '1799999000 1.2.0' ]
}

@test "the notice is light blue" {
  seed '1799999000 1.2.0'
  render NO_COLOR=
  [ "$output" = "[M] | ${ESC}[94m↑ 1.2.0 available${ESC}[0m" ]
}

@test "without emoji the arrow goes" {
  seed '1799999000 1.2.0'
  render CLAUDE_STATUSLINE_NO_EMOJI=1
  [ "$output" = '[M] | 1.2.0 available' ]
}

@test "the default segment list ends with the notice" {
  seed '1799999000 1.2.0'
  render CLAUDE_STATUSLINE_SEGMENTS=
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
}

@test "the same or an older release shows nothing" {
  local v
  for v in 1.1.0 1.0.9 0.9.99 1.0.10; do
    seed "1799999000 $v"
    render
    [ "$output" = '[M]' ] || { echo "$v: $output"; return 1; }
  done
}

@test "versions compare as numbers, part by part" {
  local v
  for v in 1.10.0 1.1.1 2.0.0 1.1.08 9999.9999.9999; do
    seed "1799999000 $v"
    render
    [ "$output" = "[M] | ↑ $v available" ] || { echo "$v: $output"; return 1; }
  done
}

@test "without a cache it claims the next check, then fetches in the background" {
  render
  [ "$output" = '[M]' ]
  # The claim is written before the render returns, so the next renders wait a day.
  [ -f "$CACHE/latest" ] || { ls -la "$CACHE" "$(dirname "$CACHE")" 2>&1; return 1; }
  wait_for_cache '1800000000 1.2.0'
  [ "$(calls)" = 1 ]
  grep -qx -- "-fsS --proto =https --max-time 5 -o /dev/null -w %{redirect_url} https://github.com/ni-c/claude-usage-statusline/releases/latest" "$LOG"
  case "$OSTYPE" in
    msys* | cygwin*) ;; # NTFS has no mode bits for mkdir -m to set
    *) [ "$(stat -c %a "$CACHE" 2>/dev/null || stat -f %Lp "$CACHE")" = 700 ] ;;
  esac

  render
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
  settle
  [ "$(calls)" = 1 ]
}

@test "a check exactly one day old is repeated, one second younger is not" {
  seed '1799913601 1.2.0'
  render
  settle
  [ "$(calls)" = 0 ]

  seed '1799913600 1.2.0'
  REDIRECT="$TAG_URL/v1.3.0"
  render
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
  wait_for_cache '1800000000 1.3.0'
  [ "$(calls)" = 1 ]
}

@test "a check dated in the future is repeated" {
  seed '1800000001 1.2.0'
  render
  wait_for_cache '1800000000 1.2.0'
  [ "$(calls)" = 1 ]
}

@test "a failed fetch keeps the version it knew, and waits a day" {
  seed '1700000000 1.2.0'
  render FAKE_CURL_EXIT=22
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
  wait_for_calls 1
  [ "$(cache)" = '1800000000 1.2.0' ]
}

@test "the render does not wait for the network" {
  local start=$SECONDS
  render FAKE_CURL_SLEEP=4
  [ "$output" = '[M]' ]
  [ $((SECONDS - start)) -lt 3 ]
}

@test "a redirect to anything but a release tag is dropped" {
  local url
  for url in '' 'https://example.com/ni-c/claude-usage-statusline/releases/tag/v1.2.0' \
    "$TAG_URL/1.2.0" "$TAG_URL/v1.2" "$TAG_URL/v1.2.3.4" "$TAG_URL/v1.2.0-rc1" \
    "$TAG_URL/v12345.0.0" "$TAG_URL/v1.2.0${ESC}[2J" "$TAG_URL/v1.2.0/../../x" \
    "$TAG_URL/v1.2.0 1.3.0" "http://github.com/ni-c/claude-usage-statusline/releases/tag/v1.2.0"; do
    rm -rf "$CACHE" "$LOG"
    REDIRECT=$url
    render
    [ "$output" = '[M]' ]
    wait_for_calls 1 || { echo "no fetch for '$url'"; return 1; }
    [ "$(cache)" = '1800000000 ' ] || { echo "'$url' became '$(cache)'"; return 1; }
  done
}

@test "a broken cache shows nothing and is checked again" {
  local line
  for line in 'garbage' '1799999000' '1799999000 ' '1799999000 1.2.0 x' \
    "1799999000 1.2.0${ESC}[2J" '1799999000 9.9.9;rm -rf ~' '1799999000 12345.0.0' \
    '1799999000 1.2' '1799999000 .1.2' '1799999000 1..2' '1799999000 1.2.3.' \
    '1799999000 -1.2.3' '1799999000 v1.2.0' '1799999000 1.2.0'$'\r' \
    '99999999999999 1.2.0' '-5 1.2.0'; do
    rm -rf "$CACHE" "$LOG"
    seed "$line"
    render
    case "$line" in
      '99999999999999 1.2.0' | '-5 1.2.0') [ "$output" = '[M] | ↑ 1.2.0 available' ] ;;
      *) [ "$output" = '[M]' ] ;;
    esac || { echo "'$line' printed '$output'"; return 1; }
    case "$line" in
      1799999000*) ;;
      *) wait_for_cache '1800000000 1.2.0' || { echo "'$line' was not checked again"; return 1; } ;;
    esac
  done
}

@test "a NUL in the cache makes the line invalid, not valid" {
  mkdir -p "$CACHE"
  printf '1799999000 1.2.0\000\n' >"$CACHE/latest"
  render
  [ "$output" = '[M]' ]
}

# Invalid UTF-8, high bytes and control characters: fixed bytes, so that a failure
# can be repeated. BSD tr and bash 3.2 are the ones that trip over these.
@test "a cache of binary junk does not reach the terminal" {
  local junk n=0
  for junk in '\377\376\200\300 \301\033[2J' '\3771799999000 1.2.0' '1799999000 1.2.\3770' \
    '\342\202\2011799999000 1.2.0' '1799999000\t1.2.0' '\r\n1799999000 1.2.0'; do
    # A directory of its own each: the check an earlier line started may still be
    # writing to the last one, and Windows starts processes slowly.
    n=$((n + 1))
    CACHE="$BATS_TEST_TMPDIR/junk-$n"
    mkdir -p "$CACHE"
    # shellcheck disable=SC2059 # the escapes are the point
    printf "$junk\n" >"$CACHE/latest"
    render
    [ "$status" -eq 0 ] || return 1
    case "$junk" in
      '\3771799999000 1.2.0' | '\342\202\2011799999000 1.2.0') [ "$output" = '[M] | ↑ 1.2.0 available' ] ;;
      *) [ "$output" = '[M]' ] ;;
    esac || { echo "'$junk' printed '$output'"; return 1; }
  done
}

@test "a huge cache is read no further than its first bytes" {
  mkdir -p "$CACHE"
  { printf '1799999000 1.2.0\n'; head -c 1000000 /dev/zero | tr '\000' x; } >"$CACHE/latest"
  render
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
}

@test "a symlink as the cache file is neither read nor replaced" {
  case "$OSTYPE" in msys* | cygwin*) skip 'ln -s copies under Git Bash' ;; esac
  mkdir -p "$CACHE"
  printf '1799999000 1.2.0\n' >"$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$CACHE/latest"
  render
  [ "$output" = '[M]' ]
  settle
  [ -L "$CACHE/latest" ]
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" = '1799999000 1.2.0' ]
  [ "$(calls)" = 0 ]
}

@test "a directory as the cache file is left alone" {
  mkdir -p "$CACHE/latest"
  render
  [ "$output" = '[M]' ]
  settle
  [ -z "$(ls -A "$CACHE/latest")" ]
  [ "$(calls)" = 0 ]
}

@test "a check never writes into a directory that took the cache file's place" {
  seed '1700000000 1.2.0'
  render FAKE_CURL_SLEEP=1
  [ "$(calls)" = 1 ] || wait_for_calls 1
  rm "$CACHE/latest"
  mkdir "$CACHE/latest"
  sleep 1.5
  [ -z "$(ls -A "$CACHE/latest")" ]
}

@test "each opt-out stops both the notice and the check" {
  local optout
  for optout in CLAUDE_STATUSLINE_UPDATE_CHECK=0 CLAUDE_STATUSLINE_UPDATE_CHECK=off \
    DO_NOT_TRACK=1 DO_NOT_TRACK=true CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; do
    rm -f "$LOG"
    seed '1700000000 1.2.0'
    render "$optout"
    [ "$output" = '[M]' ] || { echo "$optout: $output"; return 1; }
    settle
    [ "$(calls)" = 0 ] || { echo "$optout fetched"; return 1; }
    [ "$(cache)" = '1700000000 1.2.0' ]
  done
}

@test "DO_NOT_TRACK=0 is no opt-out" {
  seed '1799999000 1.2.0'
  render DO_NOT_TRACK=0
  [ "$output" = '[M] | ↑ 1.2.0 available' ]
}

@test "CLAUDE_STATUSLINE_UPDATE_CHECK=1 wins over DO_NOT_TRACK and Claude Code's switch" {
  local general
  for general in DO_NOT_TRACK=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1; do
    rm -f "$LOG"
    seed '1700000000 1.2.0'
    render "$general" CLAUDE_STATUSLINE_UPDATE_CHECK=1
    [ "$output" = '[M] | ↑ 1.2.0 available' ]
    wait_for_cache '1800000000 1.2.0'
    [ "$(calls)" = 1 ]
  done
}

@test "without the update segment there is no check at all" {
  seed '1700000000 1.2.0'
  render CLAUDE_STATUSLINE_SEGMENTS=model,dir,ctx,5h,7d
  [ "$output" = '[M]' ]
  settle
  [ "$(calls)" = 0 ]
}

@test "the cache goes under an absolute XDG_CACHE_HOME, else under ~/.cache" {
  local home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$home"
  render CLAUDE_STATUSLINE_CACHE_DIR= HOME="$home" XDG_CACHE_HOME="$BATS_TEST_TMPDIR/xdg"
  [ -f "$BATS_TEST_TMPDIR/xdg/claude-usage-statusline/latest" ]

  render CLAUDE_STATUSLINE_CACHE_DIR= HOME="$home" XDG_CACHE_HOME=relative/path
  [ -f "$home/.cache/claude-usage-statusline/latest" ]
  [ ! -e relative ]
}
