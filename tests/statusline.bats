#!/usr/bin/env bats
# statusline.sh against every case in cases.tsv, plus the cases a fixture cannot
# express. STATUSLINE_BASH picks the interpreter, so CI can hold the script to
# macOS's /bin/bash 3.2.

ESC=$'\033'

setup_file() {
  export ROOT="$BATS_TEST_DIRNAME/.."
  export WORK="$BATS_FILE_TMPDIR"
  # The test repositories must not see the developer's git configuration (signing,
  # hooks, templates), and discovery must stop at WORK so "plain" is not inside a
  # repository by accident.
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_CEILING_DIRECTORIES="$WORK"

  make_repo "$WORK/proj"
  git -C "$WORK/proj" checkout -q -b feature/x
  mkdir "$WORK/proj/sub"
  make_repo "$WORK/detached"
  git -C "$WORK/detached" checkout -q --detach
  mkdir "$WORK/plain"
}

# The same commit everywhere — fixed author, committer and dates — so the
# detached HEAD has a SHA cases.tsv can spell out.
make_repo() {
  git init -q "$1"
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
    git -C "$1" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

# fixture_file NAME → path of the fixture with the __REPO__ placeholders filled in.
fixture_file() {
  local out="$WORK/input.json"
  sed -e "s#__REPO__#$WORK/proj#g" -e "s#__DETACHED__#$WORK/detached#g" \
    -e "s#__PLAIN__#$WORK/plain#g" "$ROOT/tests/fixtures/$1.json" >"$out"
  printf '%s' "$out"
}

# run_statusline ENV-SPEC INPUT-FILE → sets $out (stdout, trailing newline kept),
# $err and $code. ENV-SPEC is the env column of cases.tsv.
run_statusline() {
  local assignments='NO_COLOR=1
CLAUDE_STATUSLINE_NOW=1800000000' pair key value
  local IFS=';'
  for pair in $1; do
    [ "$pair" = '-' ] && continue
    key=${pair%%=*} value=${pair#*=}
    assignments=$(printf '%s\n' "$assignments" | grep -v "^$key=")
    [ -n "$value" ] && assignments="$assignments
$pair"
  done
  IFS=$'\n'
  # shellcheck disable=SC2086 # one assignment per line, split on purpose
  out=$(env -u NO_COLOR -u CLAUDE_STATUSLINE_WARN -u CLAUDE_STATUSLINE_NOTICE \
    -u CLAUDE_STATUSLINE_SEGMENTS -u CLAUDE_STATUSLINE_NO_EMOJI -u CLAUDE_STATUSLINE_NOW \
    $assignments "${STATUSLINE_BASH:-bash}" "$ROOT/statusline.sh" <"$2" 2>"$WORK/stderr"
    echo "code=$?")
  code=${out##*code=}
  out=${out%code=*}
  err=$(cat "$WORK/stderr")
}

expand_colours() {
  local s=$1
  s=${s//\{green\}/${ESC}[32m}
  s=${s//\{yellow\}/${ESC}[33m}
  s=${s//\{red\}/${ESC}[31m}
  s=${s//\{reset\}/${ESC}[0m}
  printf '%s' "$s"
}

@test "every case in cases.tsv" {
  local failures=0 name fixture envspec expected want
  while IFS=$'\t' read -r name fixture envspec expected; do
    case "$name" in '#'* | '') continue ;; esac
    run_statusline "$envspec" "$(fixture_file "$fixture")"
    want="$(expand_colours "$expected")"$'\n'
    if [ "$out" != "$want" ] || [ "$code" != 0 ] || [ -n "$err" ]; then
      failures=$((failures + 1))
      printf 'FAIL %s\n  want: %q\n  got:  %q (exit %s)\n  stderr: %s\n' \
        "$name" "$want" "$out" "$code" "$err"
    fi
  done <"$ROOT/tests/cases.tsv"
  [ "$failures" -eq 0 ]
}

# Git Bash copies instead of symlinking, and a copied msys binary cannot find its
# DLLs, so the tests that build a PATH out of symlinks skip there.
skip_on_git_bash() {
  case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) skip "needs real symlinks" ;; esac
}

# A PATH holding only the named commands, as symlinks.
path_with() {
  local dir="$WORK/path-$1" cmd
  shift
  mkdir -p "$dir"
  for cmd in "$@"; do ln -sf "$(command -v "$cmd")" "$dir/$cmd"; done
  printf '%s' "$dir"
}

@test "without jq it says so instead of failing" {
  skip_on_git_bash
  local p
  p=$(path_with nojq date tr)
  run env PATH="$p" "$(command -v "${STATUSLINE_BASH:-bash}")" "$ROOT/statusline.sh" <"$ROOT/tests/fixtures/full.json"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-usage-statusline: jq is required (https://jqlang.org/download/)" ]
}

@test "without git the branch segment is left out" {
  skip_on_git_bash
  local p
  p=$(path_with nogit date tr jq)
  run env PATH="$p" NO_COLOR=1 "$(command -v "${STATUSLINE_BASH:-bash}")" "$ROOT/statusline.sh" <"$(fixture_file git-branch)"
  [ "$status" -eq 0 ]
  [ "$output" = "[M] 📁 proj" ]
}

@test "copes with a jq that ends its lines with CR, as a native jq.exe under Git Bash does" {
  local dir="$WORK/crlf-jq"
  mkdir -p "$dir"
  printf '#!/bin/sh\n"%s" "$@" | sed "s/\$/\\r/"\n' "$(command -v jq)" >"$dir/jq"
  chmod +x "$dir/jq"
  [ "$(printf '{}' | "$dir/jq" -r '"x"' | od -An -c | tr -d ' ')" = 'x\r\n' ]
  run env PATH="$dir:$PATH" NO_COLOR=1 CLAUDE_STATUSLINE_NOW=1800000000 \
    "${STATUSLINE_BASH:-bash}" "$ROOT/statusline.sh" <"$ROOT/tests/fixtures/full.json"
  [ "$status" -eq 0 ]
  [ "$output" = "[Opus 5 (1M context)] 📁 my-repo | ctx 30% | 0h35 30% | ⚠ 1d 89%" ]
}

# Found by fuzz/fuzz_statusline.py: a command substitution drops NUL bytes by
# itself, but bash warns on stderr while it does, and that warning lands in the
# prompt. statusline.ps1 drops them too, so both still print the same bytes.
@test "a NUL byte in the input is dropped silently" {
  local f="$WORK/nul.json"
  printf '{"model":{"display_name":"A\000B"}}' >"$f"
  run_statusline - "$f"
  [ "$code" = 0 ]
  [ -z "$err" ]
  [ "$out" = "[AB]"$'\n' ]
}

@test "uses the current time when CLAUDE_STATUSLINE_NOW is not set" {
  local reset=$(($(date +%s) + 7200 + 30)) f="$WORK/now.json"
  printf '{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":%s}}}' "$reset" >"$f"
  run env -u CLAUDE_STATUSLINE_NOW NO_COLOR=1 "${STATUSLINE_BASH:-bash}" "$ROOT/statusline.sh" <"$f"
  [ "$status" -eq 0 ]
  [ "$output" = "[?] | 2h00 1%" ]
}
