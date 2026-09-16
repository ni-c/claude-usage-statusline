#!/usr/bin/env bash
# Renders docs/preview.svg, the picture at the top of the README, from what
# statusline.sh actually prints — so the picture cannot drift from the code.
#
#   scripts/render-preview.sh           rewrite docs/preview.svg
#   scripts/render-preview.sh --check   fail if docs/preview.svg is out of date (CI)
#
# The sample data is made up: a throwaway repository called my-project on branch
# main, and usage numbers chosen to show the three colours.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
out="$root/docs/preview.svg"
now=1800000000

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$work"
git init -q "$work/my-project"
git -C "$work/my-project" symbolic-ref HEAD refs/heads/main
GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z' \
  git -C "$work/my-project" -c user.name=preview -c user.email=preview@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m init

# sample CTX FIVE_PCT FIVE_SECONDS_LEFT SEVEN_PCT SEVEN_SECONDS_LEFT → one ANSI line
sample() {
  printf '{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":%s},"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}}}' \
    "$work/my-project" "$1" "$2" $((now + $3)) "$4" $((now + $5)) |
    env -u NO_COLOR -u CLAUDE_STATUSLINE_SEGMENTS -u CLAUDE_STATUSLINE_NO_EMOJI \
      -u CLAUDE_STATUSLINE_WARN -u CLAUDE_STATUSLINE_NOTICE \
      CLAUDE_STATUSLINE_NOW=$now bash "$root/statusline.sh"
}

xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# One ANSI line → SVG <tspan>s. Only the four codes statusline.sh emits exist.
to_tspans() {
  local s=$1 class='' code text esc=$'\033'
  while [ -n "$s" ]; do
    case "$s" in
      "${esc}["*)
        s=${s#"${esc}["}
        code=${s%%m*}
        s=${s#*m}
        case "$code" in
          32) class=green ;;
          33) class=yellow ;;
          31) class=red ;;
          *) class='' ;;
        esac
        ;;
      *)
        text=${s%%"$esc"*}
        s=${s#"$text"}
        if [ -n "$class" ]; then
          printf '<tspan class="%s">%s</tspan>' "$class" "$(xml_escape "$text")"
        else
          printf '%s' "$(xml_escape "$text")"
        fi
        ;;
    esac
  done
}

# The canvas. The README shows it at width="100%", so this is really the aspect
# ratio plus the size the text renders at when GitHub's content column is about
# this wide — which is what keeps the line legible at its natural size instead of
# being blown up. Widening it here widens the terminal, not the type.
WIDTH=800
HEIGHT=200

render() {
  local relaxed busy critical
  relaxed=$(sample 12 18 13320 23 300000)
  busy=$(sample 57 64 3900 41 200000)
  critical=$(sample 83 91 720 88 50000)
  cat <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="$WIDTH" height="$HEIGHT" viewBox="0 0 $WIDTH $HEIGHT" role="img" aria-label="Three examples of the status line: plenty left, getting busy, close to the limit">
  <style>
    .bg { fill: #0d1117; }
    .bar { fill: #161b22; }
    .line { font: 15px ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace; fill: #c9d1d9; white-space: pre; }
    .note { font: 12px ui-sans-serif, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif; fill: #8b949e; }
    .green { fill: #3fb950; }
    .yellow { fill: #d29922; }
    .red { fill: #f85149; }
  </style>
  <rect class="bg" width="$WIDTH" height="$HEIGHT" rx="10"/>
  <path class="bar" d="M0 10a10 10 0 0 1 10-10h$((WIDTH - 20))a10 10 0 0 1 10 10v18H0z"/>
  <circle cx="18" cy="14" r="5" fill="#f85149"/>
  <circle cx="36" cy="14" r="5" fill="#d29922"/>
  <circle cx="54" cy="14" r="5" fill="#3fb950"/>
  <text class="note" x="24" y="58">plenty left</text>
  <text class="line" x="24" y="80" xml:space="preserve">$(to_tspans "$relaxed")</text>
  <text class="note" x="24" y="110">getting busy</text>
  <text class="line" x="24" y="132" xml:space="preserve">$(to_tspans "$busy")</text>
  <text class="note" x="24" y="162">close to the limit</text>
  <text class="line" x="24" y="184" xml:space="preserve">$(to_tspans "$critical")</text>
</svg>
EOF
}

if [ "${1:-}" = --check ]; then
  if ! render | cmp -s - "$out"; then
    echo "docs/preview.svg is out of date: run scripts/render-preview.sh" >&2
    exit 1
  fi
  exit 0
fi

mkdir -p "$root/docs"
render >"$out"
echo "wrote $out"
