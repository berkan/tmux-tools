#!/usr/bin/env bash
# Tests for config/tmux-jump-click: picking a place by keyboard and jumping there.
# Needs tmux and python3, no Docker. Runs a private tmux server ("inner") whose
# client sits in a pane of another private server ("outer"): popups need an
# attached client, and keys typed into the outer pane reach the popup.
#
#   bash tests/click.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLICK="$HERE/../config/tmux-jump-click"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-jump-click-test.XXXXXX")" && pwd)"
OUTER="tmux-jump-click-outer-$$"
INNER="tmux-jump-click-inner-$$"
cleanup() {
    tmux -L "$INNER" kill-server 2>/dev/null || true
    tmux -L "$OUTER" kill-server 2>/dev/null || true
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

# A pane program that prints its arguments as lines, asks for mouse events
# (sgr, x10 or none), moves its cursor to a click and logs every input byte,
# as hex, to rec.log.
cat > "$SCRATCH/recorder.py" <<'EOF'
import os, re, sys, tty
log = open(sys.argv[1], "a")
tty.setraw(0)
mode = {'sgr': '\x1b[?1000h\x1b[?1006h', 'x10': '\x1b[?1000h', 'none': ''}[sys.argv[2]]
os.write(1, (mode + '\r\n'.join(sys.argv[3:])).encode())
while True:
    data = os.read(0, 64)
    log.write(data.hex()); log.flush()
    for m in re.finditer(rb'\x1b\[<0;(\d+);(\d+)M|\x1b\[M (.)(.)', data, re.S):
        col, row = (int(m[1]), int(m[2])) if m[1] else (m[3][0] - 32, m[4][0] - 32)
        os.write(1, f'\x1b[{row};{col}H'.encode())
EOF

# A one-line editor showing "> TEXT" with the cursor at the end of it. Left and
# Right move the cursor; it asks for mouse events and, with "clicks", moves the
# cursor to a click on its line (Claude Code, pi), else ignores clicks (agy).
# Logs its input like the recorder.
cat > "$SCRATCH/editor.py" <<'EOF'
import os, re, sys, tty
log = open(sys.argv[1], 'a')
clicks, text = sys.argv[2] == 'clicks', sys.argv[3]
tty.setraw(0)
pos = len(text)
os.write(1, ('\x1b[?1000h\x1b[?1006h\x1b[2J\x1b[H> ' + text).encode())
while True:
    data = os.read(0, 64)
    log.write(data.hex()); log.flush()
    for m in re.finditer(rb'\x1b\[<0;(\d+);(\d+)M|\x1b\[([CD])', data):
        if m.group(3):
            pos += 1 if m.group(3) == b'C' else -1
        elif clicks and m.group(2) == b'1':
            pos = int(m.group(1)) - 3
        pos = max(0, min(len(text), pos))
    os.write(1, f'\x1b[1;{pos + 3}H'.encode())
EOF

inner() { tmux -L "$INNER" "$@"; }
hex() { printf '%b' "$1" | od -An -tx1 | tr -d ' \n'; }

tmux -L "$OUTER" -f /dev/null new-session -d -x 60 -y 12 \
    "env -u TMUX tmux -L $INNER -f /dev/null new-session -x 60 -y 11 'sleep 600'"
for _ in $(seq 50); do inner has-session 2>/dev/null && break; sleep 0.1; done
inner set -g status off
inner set -s escape-time 0
tmux -L "$OUTER" set -s escape-time 0
PANE=$(inner display -p '#{pane_id}')
CLIENT=$(inner list-clients -F '#{client_name}')
SOCKET=$(inner display -p '#{socket_path}')

# run_pane CMD — restart the pane with CMD and wait until it has drawn.
run_pane() {
    : > "$SCRATCH/rec.log"
    inner respawn-pane -k -t "$PANE" "$1"
    sleep 0.4
}
recorder() { run_pane "python3 $SCRATCH/recorder.py $SCRATCH/rec.log $(printf '%q ' "$@")"; }
recorded() { cat "$SCRATCH/rec.log"; }

# pick KEY... — run tmux-jump-click on the pane and type KEYs into its popup.
pick() {
    rm -rf "$SCRATCH/tmp" && mkdir "$SCRATCH/tmp"
    TMUX="$SOCKET,0,0" TMPDIR="$SCRATCH/tmp" python3 "$CLICK" "$PANE" "$CLIENT" &
    local pid=$!
    # Type only once the popup has drawn and waits for keys.
    for _ in $(seq 50); do
        compgen -G "$SCRATCH/tmp/tmux-jump-click.*/ready" >/dev/null && break
        sleep 0.1
    done
    for k in "$@"; do tmux -L "$OUTER" send-keys -l "$k"; sleep 0.2; done
    for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid"; inner display-popup -C; echo "  (tmux-jump-click still running)"
    fi
    wait "$pid" 2>/dev/null || true
    sleep 0.2
}

echo "programs that ask for mouse events get a click"
recorder sgr 'alpha beta gamma' 'bravo'
pick g
expect "a single match clicks at once (SGR)" "$(hex '\e[<0;12;1M\e[<0;12;1m')" "$(recorded)"

recorder sgr 'alpha beta gamma' 'bravo'
pick b s
expect "the second label picks the second match" "$(hex '\e[<0;1;2M\e[<0;1;2m')" "$(recorded)"

recorder sgr 'alpha beta gamma' 'bravo'
pick b a
expect "the first label picks the first match" "$(hex '\e[<0;7;1M\e[<0;7;1m')" "$(recorded)"

recorder sgr 'xa-b alpha'
pick a
expect "a match inside a word is not a target" "$(hex '\e[<0;6;1M\e[<0;6;1m')" "$(recorded)"

recorder sgr 'alpha - beta'
pick -
expect "a non-word key matches anywhere" "$(hex '\e[<0;7;1M\e[<0;7;1m')" "$(recorded)"

recorder sgr '日本 gamma'
pick g
expect "wide characters take two columns" "$(hex '\e[<0;6;1M\e[<0;6;1m')" "$(recorded)"

recorder x10 'alpha beta gamma' 'bravo'
pick g
expect "legacy mouse encoding" "$(hex '\e[M ,!\e[M#,!')" "$(recorded)"

recorder sgr 'beta above' '────────' '❯ alpha beta' '────────' 'beta below' $'\e[3;3H'
pick b s
expect "a place between rules around the cursor gets a click" \
    "$(hex '\e[<0;9;3M\e[<0;9;3m')" "$(recorded)"

recorder sgr 'beta above' '────────' '❯ alpha beta' '────────' 'beta below' $'\e[3;3H'
pick b d
expect "a place outside them is jumped to in copy mode" "1 0,4 " \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}') $(recorded)"

recorder sgr '日本 gamma' '' '› alpha'
pick g
expect "copy mode counts wide characters as two columns" "1 5,0" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}')"

recorder sgr 'beta above' '── default ─────' 'alpha beta' '────────' 'beta below' $'\e[3;1H'
pick b s
expect "a rule may carry a title" "$(hex '\e[<0;7;3M\e[<0;7;3m')" "$(recorded)"

recorder sgr 'beta' '────────' 'bravo'
pick b s
expect "a rule on one side only does not limit" "$(hex '\e[<0;1;3M\e[<0;1;3m')" "$(recorded)"

recorder sgr 'beta above' '' '› alpha beta' '  bravo' '' 'beta footer' $'\e[3;3H'
pick b d
expect "without rules, the rows between blank rows around the cursor" \
    "$(hex '\e[<0;3;4M\e[<0;3;4m')" "$(recorded)"

recorder sgr 'alpha beta gamma'
pick $'\e'
expect "Esc cancels" "" "$(recorded)"

recorder sgr 'alpha beta gamma' 'bravo'
pick b $'\e'
expect "Esc at the labels cancels" "" "$(recorded)"

recorder sgr 'alpha beta gamma'
pick q
expect "a key with no match cancels" "" "$(recorded)"

recorder sgr 'alpha beta gamma'
inner copy-mode -t "$PANE"
pick g
expect "copy mode is left first" "0 $(hex '\e[<0;12;1M\e[<0;12;1m')" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode}') $(recorded)"

editor() { run_pane "python3 $SCRATCH/editor.py $SCRATCH/rec.log $1 '$2'"; }
cursor_x() { inner display -p -t "$PANE" '#{cursor_x}'; }

editor clicks 'alpha beta gamma'
pick b
expect "a click that moves the cursor is all that is sent" \
    "8 $(hex '\e[<0;9;1M\e[<0;9;1m')" "$(cursor_x) $(recorded)"

editor ignores 'alpha beta gamma'
pick b
expect "a click that does not move the cursor is followed by arrow keys" 8 "$(cursor_x)"

echo "other programs get arrow keys within the cursor's line"
# bash: type a line, move along it with tmux-jump-click, then insert X and run it.
bash_line() {
    run_pane "env -i HOME=$SCRATCH TERM=tmux-256color PS1='$ ' bash --norc --noprofile"
    inner send-keys -t "$PANE" -l "$1"
    sleep 0.2
}
ran() { inner send-keys -t "$PANE" X Enter; sleep 0.3; inner capture-pane -p -t "$PANE" -J | sed -n 2p; }

bash_line 'echo alpha beta gamma'
pick b
expect "Left keys reach the place" "alpha Xbeta gamma" "$(ran)"

bash_line 'echo alpha beta gamma'
inner send-keys -t "$PANE" Home
pick g
expect "Right keys reach the place" "alpha beta Xgamma" "$(ran)"

bash_line "echo $(printf 'w%02d ' $(seq 1 30))"
pick w a h
expect "wrapped rows count as one line" \
    "w01 w02 w03 w04 w05 Xw06 w07 w08 w09 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30" \
    "$(ran)"

run_pane "env -i HOME=$SCRATCH TERM=tmux-256color PS1='$ ' bash --norc --noprofile"
inner send-keys -t "$PANE" -l 'echo bravo'
inner send-keys -t "$PANE" Enter
sleep 0.2
inner send-keys -t "$PANE" -l 'echo alpha beta'
sleep 0.2
pick b s
expect "a place on another line is jumped to in copy mode" "1 0,1" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}')"
inner send-keys -t "$PANE" -X cancel
pick b d
expect "a place on the cursor's line still gets arrow keys" "alpha Xbeta" \
    "$(inner send-keys -t "$PANE" X Enter; sleep 0.3; inner capture-pane -p -t "$PANE" | sed -n 4p)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
