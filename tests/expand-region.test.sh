#!/usr/bin/env bash
# Tests for config/tmux-expand-region: growing and shrinking a copy-mode
# selection by regions around the cursor. Needs tmux and python3, no Docker.
# Runs a private tmux server; no client is needed.
#
#   bash tests/expand-region.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXPAND="$HERE/../config/tmux-expand-region"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-expand-region-test.XXXXXX")" && pwd)"
SERVER="tmux-expand-region-$$"
cleanup() {
    tmux -L "$SERVER" kill-server 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}

t() { tmux -L "$SERVER" "$@"; }

t -f /dev/null new-session -d -x 60 -y 10 'sleep 600'
t set -g mode-keys vi                     # tmux default when $EDITOR is vi(m)
PANE=$(t display -p '#{pane_id}')
SOCKET=$(t display -p '#{socket_path}')

# show LINE... — the pane shows these lines, then copy mode starts.
show() {
    printf '%s\n' "$@" > "$SCRATCH/text"
    t respawn-pane -k -t "$PANE" "cat $SCRATCH/text; sleep 600"
    sleep 0.3
    t copy-mode -t "$PANE"
}
# at ROW COL — put the copy-mode cursor there (rows from the top of the view).
at() {
    t send -t "$PANE" -X top-line
    t send -t "$PANE" -X start-of-line
    [ "$1" -gt 0 ] && t send -t "$PANE" -X -N "$1" cursor-down
    [ "$2" -gt 0 ] && t send -t "$PANE" -X -N "$2" cursor-right
    return 0
}
run() { TMUX="$SOCKET,0,0" python3 "$EXPAND" "$1" "$PANE"; }
selected() {
    if [ "$(t display -p -t "$PANE" '#{selection_present}')" = 1 ]; then
        t send -t "$PANE" -X copy-selection-no-clear
        t show-buffer
    fi
}
# steps ACTION... — run each action, print the selection after each, '|'-separated.
steps() {
    local out=() a
    for a in "$@"; do run "$a"; out+=("$(selected)"); done
    local IFS='|'; echo "${out[*]}"
}

echo "expanding"
show 'see (src/app.py:42, "quoted text") here'
at 0 9
expect "word, symbol, brackets, line" \
    'app|src/app.py:42|src/app.py:42, "quoted text"|(src/app.py:42, "quoted text")|see (src/app.py:42, "quoted text") here' \
    "$(steps expand expand expand expand expand)"

show 'see (src/app.py:42, "quoted text") here'
at 0 21
expect "quotes, inside then with" \
    'quoted|quoted text|"quoted text"|src/app.py:42, "quoted text"' \
    "$(steps expand expand expand expand)"

show 'if m.start() <= p: (see f(x)).'
at 0 6
expect "brackets that open in the word stay; ones that wrap it go" \
    'start|m.start()' "$(steps expand expand)"
t send -t "$PANE" -X cancel
t copy-mode -t "$PANE"
at 0 24
expect "  ... and around a sentence" 'f|f(x)' "$(steps expand expand)"

show 'call(' '    first,' '    second)' 'after'
at 1 5
expect "brackets across rows" \
    'first|first,
    second' "$(steps expand expand expand | cut -d'|' -f1,3)"

show '● First item text' '  continues here' '  and here' '● Second item' '' 'other para'
at 1 3
expect "an indented block, then its bullet, then the paragraph" \
    'continues|continues here|continues here
  and here|● First item text
  continues here
  and here|● First item text
  continues here
  and here
● Second item' "$(steps expand expand expand expand expand)"

show 'alpha beta gamma'
at 0 6
t send -t "$PANE" -X begin-selection
t send -t "$PANE" -X -N 3 cursor-left
expect "a selection made by hand grows from itself" 'alpha beta gamma' "$(steps expand)"

echo "shrinking"
show 'see (src/app.py:42, "quoted text") here'
at 0 9
expect "shrink retraces the steps, then clears" \
    'app|src/app.py:42|src/app.py:42, "quoted text"|src/app.py:42|app|' \
    "$(steps expand expand expand shrink shrink shrink)"

show 'alpha beta gamma'
at 0 6
run expand
t send -t "$PANE" -X clear-selection
t send -t "$PANE" -X begin-selection
t send -t "$PANE" -X -N 2 cursor-right
expect "after a selection by hand, shrink forgets the old steps" '' "$(steps shrink)"

echo "scrolled back"
printf 'line%02d alpha beta\n' $(seq 1 30) > "$SCRATCH/text"
t respawn-pane -k -t "$PANE" "cat $SCRATCH/text; sleep 600"
sleep 0.3
t copy-mode -t "$PANE"
t send -t "$PANE" -X -N 8 scroll-up
at 2 7
expect "regions come from the scrolled-back view" 'alpha|line16 alpha beta' "$(steps expand expand)"

echo "keys"
t set -g @expand-region-expand-key '+'
t set -g @expand-region-shrink-key '_'
TMUX="$SOCKET,0,0" python3 "$EXPAND" bind
expect "bind uses the configured keys, in both copy-mode tables" "4" \
    "$(t list-keys | grep -cE "copy-mode(-vi)? +[+_] +run-shell .*tmux-expand-region (expand|shrink)")"
t set -gu @expand-region-expand-key
t set -gu @expand-region-shrink-key
TMUX="$SOCKET,0,0" python3 "$EXPAND" bind
expect "the default keys are = and -" "4" \
    "$(t list-keys | grep -cE "copy-mode(-vi)? +[=-] +run-shell .*tmux-expand-region (expand|shrink)")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
