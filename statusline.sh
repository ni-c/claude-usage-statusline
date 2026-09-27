#!/usr/bin/env bash
# claude-usage-statusline — https://github.com/ni-c/claude-usage-statusline
#
# Reads the JSON Claude Code pipes into a status line command and prints one line:
#
#   [Opus 5.5 · high] 📁 my-repo ⎇ main | ctx 30% | 2h15 42% | ⚠ 3d 81%
#
# Written for bash 3.2 (the one macOS ships), so no associative arrays and no
# ${var,,}. Needs jq. A status line must never fail, so there is no `set -e`:
# every problem degrades to a shorter line and exit 0.

# Word splitting of the segment list must never turn a "*" into file names.
set -f

# The release this copy belongs to, stamped by scripts/stamp-release.sh. A copy taken
# from a checkout has none and never looks for updates.
STATUSLINE_VERSION=''
REPO_URL='https://github.com/ni-c/claude-usage-statusline'

# The one place that decides which JSON fields are read. Everything below works on
# the lines this prints (minus the CR a native jq.exe adds under Git Bash). Text is stripped of C0/C1 control characters, because a
# directory name is attacker-controlled and an ESC in it would be a terminal
# escape sequence. Numbers are validated here so bash arithmetic never sees
# anything but a plain integer. The second line is the model name without a
# trailing "(1M context)" or the like, unless that is all the name is. A malformed
# effort must not take the whole line down with it, hence the type checks.
read -r -d '' JQ_FILTER <<'JQ'
def clean: tostring | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode;
def num: (if type == "number" then . elif type == "string" then (tonumber? // null) else null end)
  | if . != null and (isinfinite or isnan) then null else . end;
def pct: num | if . == null then "" elif . < 0 then 0 elif . > 100 then 100 else floor end;
def epoch: num | if . == null or . < 0 or . >= 100000000000 then "" else floor end;
def base: if . == "" then "" else (sub("[/\\\\]+$"; "") | if . == "" then "/" else (split("/") | last | split("\\") | last) end) end;
(.workspace.current_dir // .cwd // "" | clean) as $dir
| (.model.display_name // .model.id // "?" | clean) as $model
| $model,
  ($model | sub(" *\\([^()]*\\)$"; "") | if . == "" then $model else . end),
  $dir,
  ($dir | base),
  (.context_window.used_percentage | pct),
  (.rate_limits.five_hour.used_percentage | pct),
  (.rate_limits.five_hour.resets_at | epoch),
  (.rate_limits.seven_day.used_percentage | pct),
  (.rate_limits.seven_day.resets_at | epoch),
  (.effort | if type == "object" then .level else null end | if type == "string" then clean else "" end),
  (if .fast_mode == true then "1" else "" end)
JQ

# Non-negative integer from the environment, or the default. Twelve digits at most,
# so bash arithmetic cannot overflow on it.
env_int() {
  case "$1" in
    '' | *[!0-9]* | ?????????????*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

is_true() {
  case "$1" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "$1" in
    0 | [Ff][Aa][Ll][Ss][Ee] | [Nn][Oo] | [Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

if ! command -v jq >/dev/null 2>&1; then
  echo "claude-usage-statusline: jq is required (https://jqlang.org/download/)"
  exit 0
fi

# tr rather than cat: a command substitution drops NUL bytes by itself, but bash
# warns on stderr while it does, and a warning in the prompt is exactly what a
# status line must not produce. Same one process, no warning.
input=$(tr -d '\000')

{
  IFS= read -r MODEL
  IFS= read -r MODEL_SHORT
  IFS= read -r DIR
  IFS= read -r DIR_NAME
  IFS= read -r CTX_PCT
  IFS= read -r FIVE_PCT
  IFS= read -r FIVE_RESET
  IFS= read -r SEVEN_PCT
  IFS= read -r SEVEN_RESET
  IFS= read -r EFFORT
  IFS= read -r FAST
} <<EOF
$(printf '%s' "$input" | jq -r "$JQ_FILTER" 2>/dev/null | tr -d '\r')
EOF

WARN=$(env_int "${CLAUDE_STATUSLINE_WARN:-}" 80)
NOTICE=$(env_int "${CLAUDE_STATUSLINE_NOTICE:-}" 50)
NOW=$(env_int "${CLAUDE_STATUSLINE_NOW:-}" "$(date +%s)")

# Both on unless switched off, so they read the "false" words rather than the "true" ones.
is_false "${CLAUDE_STATUSLINE_SHORT_MODEL:-}" || MODEL=$MODEL_SHORT
is_false "${CLAUDE_STATUSLINE_EFFORT:-}" && EFFORT=''

if is_true "${CLAUDE_STATUSLINE_NO_EMOJI:-}"; then
  FOLDER='' BRANCH_OPEN='(' BRANCH_CLOSE=')' WARN_MARK='! ' FAST_MARK='fast' UP_MARK=''
else
  FOLDER='📁 ' BRANCH_OPEN='⎇ ' BRANCH_CLOSE='' WARN_MARK='⚠ ' FAST_MARK='⚡' UP_MARK='↑ '
fi

# https://no-color.org: present and not empty disables colour.
if [ -n "${NO_COLOR:-}" ]; then
  GREEN='' YELLOW='' RED='' BLUE='' RESET=''
else
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' BLUE=$'\033[94m' RESET=$'\033[0m'
fi

# metric LABEL PERCENT → "LABEL 42%", coloured, with a warning mark at the threshold.
metric() {
  local color=$GREEN mark=''
  if [ "$2" -ge "$WARN" ]; then
    color=$RED mark=$WARN_MARK
  elif [ "$2" -ge "$NOTICE" ]; then
    color=$YELLOW
  fi
  printf '%s%s%s %s%%%s' "$color" "$mark" "$1" "$2" "$RESET"
}

# Seconds until an epoch, never negative.
until_reset() {
  local diff=$(($1 - NOW))
  [ "$diff" -lt 0 ] && diff=0
  printf '%s' "$diff"
}

git_branch() {
  [ -n "$DIR" ] && command -v git >/dev/null 2>&1 || return 0
  # GIT_OPTIONAL_LOCKS=0: never take index.lock away from a git the user is running.
  GIT_OPTIONAL_LOCKS=0 git -C "$DIR" symbolic-ref --short -q HEAD 2>/dev/null ||
    GIT_OPTIONAL_LOCKS=0 git -C "$DIR" rev-parse --short HEAD 2>/dev/null
}

# A release version: three parts of one to four digits. Whatever comes from the cache
# file or from the network passes through here before it is used anywhere.
is_version() {
  case "$1" in
    '' | *[!0-9.]* | .* | *. | *..*) return 1 ;;
  esac
  local IFS=. part count=0
  for part in $1; do
    case "$part" in ?????*) return 1 ;; esac
    count=$((count + 1))
  done
  [ "$count" -eq 3 ]
}

# version_newer A B → true when release A is later than release B. 10#: "08" is not octal.
version_newer() {
  local IFS=.
  # shellcheck disable=SC2086 # split on the dots, on purpose
  set -- $1 $2
  [ $((10#$1 * 100000000 + 10#$2 * 10000 + 10#$3)) -gt $((10#$4 * 100000000 + 10#$5 * 10000 + 10#$6)) ]
}

# On by default. DO_NOT_TRACK and Claude Code's own switch for non-essential traffic
# turn it off too, unless CLAUDE_STATUSLINE_UPDATE_CHECK asks for it by name.
update_check_allowed() {
  is_version "$STATUSLINE_VERSION" || return 1
  is_false "${CLAUDE_STATUSLINE_UPDATE_CHECK:-}" && return 1
  is_true "${CLAUDE_STATUSLINE_UPDATE_CHECK:-}" && return 0
  case "${DO_NOT_TRACK:-}" in '' | 0) ;; *) return 1 ;; esac
  [ -z "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" ]
}

# XDG_CACHE_HOME counts only as an absolute path, as the XDG spec says.
cache_dir() {
  if [ -n "${CLAUDE_STATUSLINE_CACHE_DIR:-}" ]; then
    printf '%s' "$CLAUDE_STATUSLINE_CACHE_DIR"
    return
  fi
  case "${XDG_CACHE_HOME:-}" in
    /*) printf '%s/claude-usage-statusline' "$XDG_CACHE_HOME" ;;
    *) [ -n "${HOME:-}" ] && printf '%s/.cache/claude-usage-statusline' "$HOME" ;;
  esac
}

# write_cache DIR VERSION → "<now> <version>" into DIR/latest, whole or not at all.
write_cache() {
  local tmp="$1/latest.$$.tmp"
  if (umask 077 && printf '%s %s\n' "$NOW" "$2" >"$tmp") 2>/dev/null && mv -f "$tmp" "$1/latest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Claims the next check before it starts, so the renders of the next seconds do not
# each start one, then asks GitHub in the background: the status line never waits
# for the network. Only the redirect of /releases/latest is read, so there is no
# API, no JSON and no rate limit, and anything but the expected tag URL is dropped.
start_update_check() {
  command -v curl >/dev/null 2>&1 || return 0
  # Private where the file system can say so. Not mkdir -m: under Git Bash it can
  # fail where a plain mkdir works, and a chmod that fails costs nothing.
  mkdir -p "$1" 2>/dev/null || return 0
  chmod 700 "$1" 2>/dev/null
  write_cache "$1" "$2" || return 0
  (
    url=$(curl -fsS --proto '=https' --max-time 5 -o /dev/null -w '%{redirect_url}' \
      "$REPO_URL/releases/latest" 2>/dev/null) || exit 0
    case "$url" in "$REPO_URL/releases/tag/v"*) ;; *) exit 0 ;; esac
    tag=${url#"$REPO_URL/releases/tag/v"}
    is_version "$tag" && write_cache "$1" "$tag"
  ) </dev/null >/dev/null 2>&1 &
}

# Prints the latest release when it is newer than this copy. Reads only the cache;
# a check older than a day (or dated in the future) starts the next one.
update_notice() {
  update_check_allowed || return 0
  local dir file line='' checked latest
  dir=$(cache_dir)
  [ -n "$dir" ] || return 0
  file="$dir/latest"
  # A symlink or anything but a plain file is not ours: never read through it,
  # never replace it.
  [ -L "$file" ] && return 0
  if [ -e "$file" ]; then
    [ -f "$file" ] || return 0
    # Every byte but digits, dots and spaces becomes a "?", which no check lets
    # through: a NUL would make bash warn on stderr, a CR vanishes in Git Bash's
    # command substitutions, and invalid UTF-8 makes BSD tr and bash 3.2's pattern
    # matching stumble. Byte-wise, the result is the same on every platform.
    line=$(head -c 64 "$file" 2>/dev/null | LC_ALL=C tr -c '0-9. \n' '?' 2>/dev/null | head -n 1)
  fi
  checked=${line%% *} latest=${line#* }
  case "$checked" in '' | *[!0-9]* | ?????????????*) checked='' ;; esac
  is_version "$latest" || latest=''
  if [ -z "$checked" ] || [ "$checked" -gt "$NOW" ] || [ $((NOW - checked)) -ge 86400 ]; then
    start_update_check "$dir" "$latest"
  fi
  [ -n "$latest" ] && version_newer "$latest" "$STATUSLINE_VERSION" &&
    printf '%s%s%s available%s' "$BLUE" "$UP_MARK" "$latest" "$RESET"
}

segment() {
  case "$1" in
    model)
      local text=${MODEL:-?}
      [ -n "$EFFORT" ] && text="$text · $EFFORT"
      [ -n "$FAST" ] && text="$text · $FAST_MARK"
      printf '[%s]' "$text"
      ;;
    dir) [ -n "$DIR_NAME" ] && printf '%s%s' "$FOLDER" "$DIR_NAME" ;;
    git)
      local branch
      branch=$(git_branch | tr -d '\000-\037\177')
      [ -n "$branch" ] && printf '%s%s%s' "$BRANCH_OPEN" "$branch" "$BRANCH_CLOSE"
      ;;
    ctx) [ -n "$CTX_PCT" ] && metric ctx "$CTX_PCT" ;;
    5h)
      [ -n "$FIVE_PCT" ] || return 0
      local label=5h
      if [ -n "$FIVE_RESET" ]; then
        local diff
        diff=$(until_reset "$FIVE_RESET")
        label=$(printf '%dh%02d' $((diff / 3600)) $((diff % 3600 / 60)))
      fi
      metric "$label" "$FIVE_PCT"
      ;;
    7d)
      [ -n "$SEVEN_PCT" ] || return 0
      local label=7d
      if [ -n "$SEVEN_RESET" ]; then
        local diff
        diff=$(until_reset "$SEVEN_RESET")
        # Whole days, rounded up: "1d" means "resets within the next day".
        label="$(((diff + 86399) / 86400))d"
      fi
      metric "$label" "$SEVEN_PCT"
      ;;
    update) update_notice ;;
  esac
}

# Keep the known names in the order given. A list with none of them falls back to
# the default rather than to an empty line.
SEGMENTS=''
for name in $(printf '%s' "${CLAUDE_STATUSLINE_SEGMENTS:-}" | tr ',' ' '); do
  case "$name" in
    model | dir | git | ctx | 5h | 7d | update) SEGMENTS="$SEGMENTS $name" ;;
  esac
done
[ -n "$SEGMENTS" ] || SEGMENTS='model dir git ctx 5h 7d update'

LINE=''
for name in $SEGMENTS; do
  text=$(segment "$name")
  [ -n "$text" ] || continue
  case "$name" in
    ctx | 5h | 7d | update) sep=' | ' ;;
    *) sep=' ' ;;
  esac
  if [ -n "$LINE" ]; then LINE="$LINE$sep$text"; else LINE=$text; fi
done

printf '%s\n' "$LINE"
