#!/usr/bin/env bash
# claude-usage-statusline — https://github.com/ni-c/claude-usage-statusline
#
# Reads the JSON Claude Code pipes into a status line command and prints one line:
#
#   [Opus 5] 📁 my-repo ⎇ main | ctx 30% | 2h15 42% | ⚠ 3d 81%
#
# Written for bash 3.2 (the one macOS ships), so no associative arrays and no
# ${var,,}. Needs jq. A status line must never fail, so there is no `set -e`:
# every problem degrades to a shorter line and exit 0.

# Word splitting of the segment list must never turn a "*" into file names.
set -f

# The one place that decides which JSON fields are read. Everything below works on
# the lines this prints (minus the CR a native jq.exe adds under Git Bash). Text is stripped of C0/C1 control characters, because a
# directory name is attacker-controlled and an ESC in it would be a terminal
# escape sequence. Numbers are validated here so bash arithmetic never sees
# anything but a plain integer.
read -r -d '' JQ_FILTER <<'JQ'
def clean: tostring | explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode;
def num: (if type == "number" then . elif type == "string" then (tonumber? // null) else null end)
  | if . != null and (isinfinite or isnan) then null else . end;
def pct: num | if . == null then "" elif . < 0 then 0 elif . > 100 then 100 else floor end;
def epoch: num | if . == null or . < 0 or . >= 100000000000 then "" else floor end;
def base: if . == "" then "" else (sub("[/\\\\]+$"; "") | if . == "" then "/" else (split("/") | last | split("\\") | last) end) end;
(.workspace.current_dir // .cwd // "" | clean) as $dir
| (.model.display_name // .model.id // "?" | clean),
  $dir,
  ($dir | base),
  (.context_window.used_percentage | pct),
  (.rate_limits.five_hour.used_percentage | pct),
  (.rate_limits.five_hour.resets_at | epoch),
  (.rate_limits.seven_day.used_percentage | pct),
  (.rate_limits.seven_day.resets_at | epoch)
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

if ! command -v jq >/dev/null 2>&1; then
  echo "claude-usage-statusline: jq is required (https://jqlang.org/download/)"
  exit 0
fi

input=$(cat)

{
  IFS= read -r MODEL
  IFS= read -r DIR
  IFS= read -r DIR_NAME
  IFS= read -r CTX_PCT
  IFS= read -r FIVE_PCT
  IFS= read -r FIVE_RESET
  IFS= read -r SEVEN_PCT
  IFS= read -r SEVEN_RESET
} <<EOF
$(printf '%s' "$input" | jq -r "$JQ_FILTER" 2>/dev/null | tr -d '\r')
EOF

WARN=$(env_int "${CLAUDE_STATUSLINE_WARN:-}" 80)
NOTICE=$(env_int "${CLAUDE_STATUSLINE_NOTICE:-}" 50)
NOW=$(env_int "${CLAUDE_STATUSLINE_NOW:-}" "$(date +%s)")

if is_true "${CLAUDE_STATUSLINE_NO_EMOJI:-}"; then
  FOLDER='' BRANCH_OPEN='(' BRANCH_CLOSE=')' WARN_MARK='! '
else
  FOLDER='📁 ' BRANCH_OPEN='⎇ ' BRANCH_CLOSE='' WARN_MARK='⚠ '
fi

# https://no-color.org: present and not empty disables colour.
if [ -n "${NO_COLOR:-}" ]; then
  GREEN='' YELLOW='' RED='' RESET=''
else
  GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' RESET=$'\033[0m'
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

segment() {
  case "$1" in
    model) printf '[%s]' "${MODEL:-?}" ;;
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
  esac
}

# Keep the known names in the order given. A list with none of them falls back to
# the default rather than to an empty line.
SEGMENTS=''
for name in $(printf '%s' "${CLAUDE_STATUSLINE_SEGMENTS:-}" | tr ',' ' '); do
  case "$name" in
    model | dir | git | ctx | 5h | 7d) SEGMENTS="$SEGMENTS $name" ;;
  esac
done
[ -n "$SEGMENTS" ] || SEGMENTS='model dir git ctx 5h 7d'

LINE=''
for name in $SEGMENTS; do
  text=$(segment "$name")
  [ -n "$text" ] || continue
  case "$name" in
    ctx | 5h | 7d) sep=' | ' ;;
    *) sep=' ' ;;
  esac
  if [ -n "$LINE" ]; then LINE="$LINE$sep$text"; else LINE=$text; fi
done

printf '%s\n' "$LINE"
