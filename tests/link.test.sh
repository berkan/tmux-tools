#!/usr/bin/env bash
# Tests for config/tmux-link: acting on the hyperlink (OSC 8) under the copy
# cursor. A scratch tmux server runs a program that prints links, then takes
# typed text as an editor would; the copy cursor is put on a link and the
# script is run as the copy-mode bindings run it. Opening needs a client: a
# client of the server runs in a pane of another. Needs tmux and python3, no
# Docker.
#
#   bash tests/link.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINK="$HERE/../config/tmux-link"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-link-test.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
unset TMUX
cleanup() {
    TMUX_TMPDIR="$SCRATCH/o" tmux kill-server 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
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

F="$SCRATCH/some dir/notes.md"
mkdir -p "$SCRATCH/some dir"; echo hello > "$F"
FURL="file://${SCRATCH// /%20}/some%20dir/notes.md"

# The program: the lines given (with links), then what is typed, which it
# writes to a file (Enter ends nothing; Backspace deletes).
cat > "$SCRATCH/prog.py" <<'EOF'
import os, sys, tty
out = sys.argv[1]
tty.setraw(0)
os.write(1, ('\r\n'.join(sys.argv[2:]) + '\r\n> ').encode())
text = ''
while True:
    for ch in os.read(0, 256).decode('utf-8', 'replace'):
        if ch == '\x7f':
            text = text[:-1]
        elif ch.isprintable():
            text += ch
    open(out, 'w').write(text)
    os.write(1, ('\r\x1b[K> ' + text).encode())
EOF
link() { printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$1" "$2"; }

tmux -f /dev/null new-session -d -x 100 -y 10 'sleep 600'
tmux set -g mode-keys vi
tmux set -s escape-time 0
PANE=$(tmux display -p '#{pane_id}')

# prog LINE... — restart the pane with the program under LINEs.
prog() {
    : > "$SCRATCH/typed"
    tmux respawn-pane -k -t "$PANE" "python3 $SCRATCH/prog.py $SCRATCH/typed $(printf '%q ' "$@")"
    sleep 0.4
}
# at ROW COL — the copy cursor to ROW (from the top of the screen) and COL.
at() {
    tmux copy-mode -t "$PANE"
    tmux send -t "$PANE" -X top-line
    tmux send -t "$PANE" -X start-of-line
    [ "$1" -gt 0 ] && tmux send -t "$PANE" -N "$1" -X cursor-down
    [ "$2" -gt 0 ] && tmux send -t "$PANE" -N "$2" -X cursor-right
    return 0
}
run() { python3 "$LINK" "$@"; sleep 0.2; }
typed() { cat "$SCRATCH/typed"; }
in_mode() { tmux display -p -t "$PANE" '#{pane_in_mode}'; }

echo "target"
prog "see $(link "$FURL" notes.md) and $(link https://example.com/a?b=1 the-site) here" \
    "日本 $(link https://example.com/wide wide)"
at 0 5
expect "a file link: its path" "$F" "$(run target "$PANE")"
at 0 6
expect "  ... anywhere on it" "$F" "$(run target "$PANE")"
at 0 3
expect "off a link: nothing" "" "$(run target "$PANE")"
at 0 18
expect "another link: as it is" "https://example.com/a?b=1" "$(run target "$PANE")"
at 1 5
expect "after wide characters" "https://example.com/wide" "$(run target "$PANE")"

lines=("$(link "$FURL" notes.md) up in the history")
for i in $(seq 14); do lines+=("line $i"); done
prog "${lines[@]}"
tmux copy-mode -t "$PANE"; tmux send -t "$PANE" -X history-top; tmux send -t "$PANE" -X start-of-line
expect "in the history, scrolled back to" "$F" "$(run target "$PANE")"
tmux send -t "$PANE" -X cancel

echo "copy, paste, quote"
prog "see $(link "$FURL" notes.md) here"
at 0 5; run copy "$PANE"
expect "copy: the path to the buffer" "$F" "$(tmux show-buffer)"
expect "  ... and copy mode is left" 0 "$(in_mode)"
at 0 5; run paste "$PANE"
expect "paste: the path typed in" "$F" "$(typed)"
prog "see $(link "$FURL" notes.md) here"
at 0 5; run quote "$PANE"
expect "quote: as quote-reply does" "re: \"$F\" -- " "$(typed)"
prog "see $(link "$FURL" notes.md) here"
at 0 1; run paste "$PANE"
expect "off a link: nothing, still in copy mode" "1 " "$(in_mode)$(typed) "

echo "open"
mkdir -p "$SCRATCH/o"
TMUX_TMPDIR="$SCRATCH/o" tmux -f /dev/null new-session -d -x 100 -y 11 \
    "env -u TMUX TMUX_TMPDIR=$SCRATCH tmux attach"
sleep 0.8
CLIENT=$(tmux list-clients -F '#{client_name}' | head -1)
cat > "$SCRATCH/editor" <<EOF
#!/bin/sh
printf '%s' "\$1" > "$SCRATCH/opened"
EOF
chmod +x "$SCRATCH/editor"
opened() { sleep 0.6; cat "$SCRATCH/opened" 2>/dev/null; rm -f "$SCRATCH/opened"; }
prog "see $(link "$FURL" notes.md) and $(link "file://$SCRATCH/gone.md" gone.md) $(link https://example.com/x x)"
at 0 5; VISUAL="$SCRATCH/editor" run open "$PANE" "$CLIENT"
expect "a file: in \$VISUAL, in a popup" "$F" "$(opened)"
at 0 19; VISUAL="$SCRATCH/editor" run open "$PANE" "$CLIENT"
expect "a file not here: not opened" "" "$(opened)"
at 0 25; VISUAL="$SCRATCH/editor" run open "$PANE" "$CLIENT"
expect "a web link: nothing opens it here, so it is copied" "https://example.com/x" "$(opened)$(tmux show-buffer)"
tmux send -t "$PANE" -X cancel
prog 'nothing here' 'nor here'
at 1 2
VISUAL="$SCRATCH/editor" run open "$PANE" "$CLIENT" cursor-up
expect "off a link: the key's own command instead, from where the cursor was" "1 2 0" \
    "$(opened)$(in_mode) $(tmux display -p -t "$PANE" '#{copy_cursor_x} #{copy_cursor_y}')"
TMUX_TMPDIR="$SCRATCH/o" tmux kill-server

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
