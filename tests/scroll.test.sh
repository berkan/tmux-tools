#!/usr/bin/env bash
# Tests for bin/tmux-scroll: M-[ and M-] scroll a pane from the keyboard, as
# the mouse wheel does. In a plain pane, copy mode, entered when needed and
# left at the bottom; in an app that has turned the mouse on, a wheel event
# sent to it. A scratch tmux server; its client runs in a pane of a second
# scratch server, and keys typed there reach the first as from a terminal,
# through its bindings. Needs tmux 3.4 or newer and python3.
#
#   bash tests/scroll.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-sc.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
export TMPDIR="$SCRATCH"
unset TMUX
cleanup() {
    TMUX_TMPDIR="$SCRATCH/o" tmux kill-server 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
SC="$HERE/../bin/tmux-scroll"

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}

# An app that turns on mouse reporting (SGR) and writes what it reads, each
# read on its own line, ESC as \e.
cat > "$SCRATCH/mouse.py" <<'EOF'
import os, sys, tty
tty.setraw(0)
os.write(1, b'\x1b[?1000h\x1b[?1006h')
out = open(sys.argv[1], 'a', buffering=1)
while True:
    out.write(os.read(0, 256).decode('utf-8', 'replace').replace('\x1b', r'\e') + '\n')
EOF

tmux -f /dev/null new-session -d -x 80 -y 13 "seq 200; exec sleep 600"
tmux set -s escape-time 0
tmux set -g history-limit 1000
PANE=$(tmux display -p '#{pane_id}')
mkdir -p "$SCRATCH/o"
TMUX_TMPDIR="$SCRATCH/o" tmux -f /dev/null new-session -d -x 80 -y 14 "env -u TMUX TMUX_TMPDIR=$SCRATCH tmux attach"
TMUX_TMPDIR="$SCRATCH/o" tmux set -s escape-time 0
sleep 0.8
sh "$SC" bind

# The keys as a terminal sends them: ESC and the character.
press() {
    local seq
    case "$1" in
        'M-[') seq=$'\e[' ;; 'M-]') seq=$'\e]' ;; 'M-k') seq=$'\ek' ;;
    esac
    TMUX_TMPDIR="$SCRATCH/o" tmux send-keys -l -- "$seq"
    sleep 0.4
}
state() { tmux display -p -t "$PANE" '#{pane_in_mode} #{scroll_position}'; }

echo "a plain pane: copy mode"
press 'M-]'
expect "down at the bottom: nothing" '0 ' "$(state)"
press 'M-['
expect "up enters copy mode, 5 lines up" '1 5' "$(state)"
press 'M-['
expect "  ... and again" '1 10' "$(state)"
press 'M-]'
expect "down: 5 lines down" '1 5' "$(state)"
press 'M-]'
expect "  ... back at the bottom, copy mode left" '0 ' "$(state)"

echo "options"
tmux set -g @scroll-lines 3
tmux set -g @scroll-up-key M-k
sh "$SC" bind
press 'M-k'
expect "@scroll-up-key and @scroll-lines" '1 3' "$(state)"
tmux send -t "$PANE" -X cancel
tmux set -gu @scroll-lines; tmux set -gu @scroll-up-key
tmux unbind -n M-k
sh "$SC" bind

echo "an app with the mouse on: wheel events"
: > "$SCRATCH/got"
tmux respawn-pane -k -t "$PANE" "python3 $SCRATCH/mouse.py $SCRATCH/got"
sleep 0.6
x=$(( $(tmux display -p -t "$PANE" '#{pane_width}') / 2 + 1 ))
y=$(( $(tmux display -p -t "$PANE" '#{pane_height}') / 3 + 1 ))
press 'M-['
press 'M-]'
expect "wheel up then down, in the upper middle" \
    "\\e[<64;$x;${y}M \\e[<65;$x;${y}M" "$(paste -sd ' ' "$SCRATCH/got")"
expect "  ... no copy mode" '0 ' "$(state)"
: > "$SCRATCH/got"
tmux set -g @scroll-at '1;2'
press 'M-['
expect "@scroll-at, where the wheel is" '\e[<64;1;2M' "$(cat "$SCRATCH/got")"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
