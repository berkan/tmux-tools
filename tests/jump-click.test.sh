#!/usr/bin/env bash
# Tests for config/tmux-jump-click: picking a place by keyboard and jumping there.
# Needs tmux and python3, no Docker. Runs a private tmux server ("inner") whose
# client sits in a pane of another private server ("outer"): popups need an
# attached client, and keys typed into the outer pane reach the popup.
#
#   bash tests/click.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLICK="$HERE/../bin/tmux-jump-click"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-jump-click-test.XXXXXX")" && pwd)"
OUTER="tmux-jump-click-outer-$$"
INNER="tmux-jump-click-inner-$$"
cleanup() {
    tmux -L "$INNER" kill-server 2>/dev/null || true
    tmux -L "$OUTER" kill-server 2>/dev/null || true
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$INNER" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$OUTER"   # tmux leaves them
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
inner set -g mode-keys vi                 # tmux default when $EDITOR is vi(m)
inner set -s escape-time 0
tmux -L "$OUTER" set -s escape-time 0
PANE=$(inner display -p '#{pane_id}')
CLIENT=$(inner list-clients -F '#{client_name}')
SOCKET=$(inner display -p '#{socket_path}')

# run_pane CMD, or PROGRAM ARG... — restart the pane with it and wait until it has drawn.
run_pane() {
    : > "$SCRATCH/rec.log"
    inner respawn-pane -k -t "$PANE" "$@"
    sleep 0.4
}
# as arguments, run without a shell: /bin/sh may be dash, which has no $'..'
recorder() { run_pane python3 "$SCRATCH/recorder.py" "$SCRATCH/rec.log" "$@"; }
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

echo "labels"
# Labels never start another label, are unique, and get no shorter down the
# list (nearest first); 30 places leave 25 one-key labels.
expect "labels are prefix-free, shortest for the nearest" ok "$(python3 - "$CLICK" <<'EOF'
import importlib.machinery as m, sys
sys.dont_write_bytecode = True
c = m.SourceFileLoader('c', sys.argv[1]).load_module()
for n in range(1, 1001):
    ls = c.labels_for(n)
    assert len(ls) == n == len(set(ls)), n
    assert not any(a != b and b.startswith(a) for a in ls for b in ls), n
    assert [len(x) for x in ls] == sorted(len(x) for x in ls), n
assert sum(len(x) == 1 for x in c.labels_for(30)) == 25
print('ok')
EOF
)"

expect "^ is the start of each line with text, past spaces and marks (⏺ │)" ok "$(python3 - "$CLICK" <<'EOF'
import importlib.machinery as m, sys
sys.dont_write_bytecode = True
c = m.SourceFileLoader('c', sys.argv[1]).load_module()
screen = ['first line', '   indented', '', '⏺ said this', '│ in a box', '- item ^ here', '日本 wide']
got = c.matches(screen, '^')
assert got == [(0, 0), (1, 3), (3, 2), (4, 2), (5, 0), (6, 0)], got
print('ok')
EOF
)"

echo "programs that ask for mouse events get a click"
recorder sgr 'alpha beta gamma' 'bravo'
pick g
expect "a single match clicks at once (SGR)" "$(hex '\e[<0;12;1M\e[<0;12;1m')" "$(recorded)"

recorder sgr 'alpha beta gamma' 'bravo'
pick b a
expect "the match nearest the cursor gets the first label" "$(hex '\e[<0;1;2M\e[<0;1;2m')" "$(recorded)"

recorder sgr 'alpha beta gamma' 'bravo'
pick b s
expect "a farther match gets a later label" "$(hex '\e[<0;7;1M\e[<0;7;1m')" "$(recorded)"

recorder sgr 'beta' '────────' '❯ a' '' '' '' 'beta' '────────' $'\e[3;3H'
pick b a
expect "the input box comes first, even when farther" "$(hex '\e[<0;1;7M\e[<0;1;7m')" "$(recorded)"

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
pick b a
expect "a place between rules around the cursor gets a click" \
    "$(hex '\e[<0;9;3M\e[<0;9;3m')" "$(recorded)"

recorder sgr 'beta above' '────────' '❯ alpha beta' '────────' 'beta below' $'\e[3;3H'
pick b d
expect "a place outside them is jumped to in copy mode" "1 0,4 " \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}') $(recorded)"
expect "  ... with a selection started there" "1 0,4" \
    "$(inner display -p -t "$PANE" '#{selection_active} #{selection_start_x},#{e|-:#{selection_start_y},#{history_size}}')"

recorder sgr '' '' 'alpha beta' '' '› x'
pick b
expect "copy mode lands right below empty top rows" "1 6,2" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}')"

recorder sgr '日本 gamma' '' '› alpha'
pick g
expect "copy mode counts wide characters as two columns" "1 5,0" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}')"

recorder sgr 'beta above' '── default ─────' 'alpha beta' '────────' 'beta below' $'\e[3;1H'
pick b a
expect "a rule may carry a title" "$(hex '\e[<0;7;3M\e[<0;7;3m')" "$(recorded)"

recorder sgr 'beta' '────────' 'bravo'
pick b a
expect "a rule on one side only does not limit" "$(hex '\e[<0;1;3M\e[<0;1;3m')" "$(recorded)"

recorder sgr 'beta above' '' '› alpha beta' '  bravo' '' 'beta footer' $'\e[3;3H'
pick b s
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

recorder sgr 'alpha beta gamma' 'bravo'
pick b $'\x7f' g
expect "Backspace at the labels takes back the character" "$(hex '\e[<0;12;1M\e[<0;12;1m')" "$(recorded)"

# 30 places: the last five labels take two keys, m and then another.
recorder sgr "$(printf 'b %.0s' $(seq 30))"
pick b a
first_label=$(recorded)
recorder sgr "$(printf 'b %.0s' $(seq 30))"
pick b m $'\x7f' a
expect "Backspace takes back the first key of a label" "$first_label" "$(recorded)"

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
expect "  ... and starts no copy mode or selection" 0 "$(inner display -p -t "$PANE" '#{pane_in_mode}')"

echo "in a copy-mode selection, the pick moves the selection's end"
copied() {
    inner send-keys -t "$PANE" -X copy-selection-no-clear
    inner show-buffer
}
recorder sgr 'alpha beta gamma' 'bravo delta'
inner copy-mode -t "$PANE"
inner send-keys -t "$PANE" -X top-line
inner send-keys -t "$PANE" -X start-of-line
inner send-keys -t "$PANE" -X begin-selection
pick d
expect "the selection runs from its start to the pick, in copy mode, no click" \
    "1 alpha beta gamma
bravo d " "$(inner display -p -t "$PANE" '#{pane_in_mode}') $(copied) $(recorded)"

recorder sgr 'alpha beta gamma' 'bravo delta'
inner copy-mode -t "$PANE"
inner send-keys -t "$PANE" -X top-line
inner send-keys -t "$PANE" -X start-of-line
inner send-keys -t "$PANE" -X -N 6 cursor-right
inner send-keys -t "$PANE" -X begin-selection
inner send-keys -t "$PANE" -X cursor-down
rm -rf "$SCRATCH/tmp" && mkdir "$SCRATCH/tmp"
TMUX="$SOCKET,0,0" TMPDIR="$SCRATCH/tmp" python3 "$CLICK" "$PANE" "$CLIENT" &
pid=$!
for _ in $(seq 50); do compgen -G "$SCRATCH/tmp/tmux-jump-click.*/ready" >/dev/null && break; sleep 0.1; done
row0=$(tmux -L "$OUTER" capture-pane -ep | head -1)
tmux -L "$OUTER" send-keys Escape
wait "$pid" 2>/dev/null || true
expect "the selection's start is marked: black on yellow" yes \
    "$(python3 -c 'import re,sys; print("yes" if re.search(r"\x1b\[[0-9;]*43[0-9;]*m(\x1b\[[0-9;]*m)*b", sys.argv[1]) else "no: " + repr(sys.argv[1]))' "$row0")"
inner send-keys -t "$PANE" -X cancel

recorder sgr $(printf 'row%02d ' $(seq 1 30))
inner copy-mode -t "$PANE"
inner send-keys -t "$PANE" -X -N 12 scroll-up
inner send-keys -t "$PANE" -X top-line
inner send-keys -t "$PANE" -X start-of-line
inner send-keys -t "$PANE" -X begin-selection
top=$(inner capture-pane -p -t "$PANE" -S "-$(inner display -p -t "$PANE" '#{scroll_position}')" | head -1)
pick r s
expect "  ... from the scrolled-back view" "$top
${top:0:1}" "$(copied)"
inner send-keys -t "$PANE" -X cancel

echo "keys"
inner set -g @jump-click-key M-j
TMUX="$SOCKET,0,0" python3 "$CLICK" bind
expect "bind uses the configured key" 1 \
    "$(inner list-keys -T prefix | grep -cE "prefix +M-j +run-shell .*tmux-jump-click '#\{pane_id\}' '#\{client_name\}'")"
inner set -g @jump-click-key 'j C-b'
TMUX="$SOCKET,0,0" python3 "$CLICK" bind
expect "several keys, space-separated, are all bound; the old one is unbound" "1 1 0" \
    "$(inner list-keys -T prefix | grep -cE "prefix +j +run-shell .*tmux-jump-click") $(inner list-keys -T prefix | grep -cE "prefix +C-b +run-shell .*tmux-jump-click") $(inner list-keys -T prefix | grep -cE "prefix +M-j ")"
inner set -gu @jump-click-key
TMUX="$SOCKET,0,0" python3 "$CLICK" bind
expect "the default key is C-j, and the old keys are unbound" "1 0 0" \
    "$(inner list-keys -T prefix | grep -cE "prefix +C-j +run-shell .*tmux-jump-click") $(inner list-keys -T prefix | grep -cE "prefix +j ") $(inner list-keys -T prefix | grep -cE "prefix +C-b ")"
# A key given up and bound to something else since (tmux.conf, sourced again)
# keeps that binding.
inner set -g @jump-click-key 'j C-j'
inner set -g @jump-click-mark-keys 'C-a'
TMUX="$SOCKET,0,0" python3 "$CLICK" bind
inner set -g @jump-click-key C-j
inner set -gu @jump-click-mark-keys
inner bind j last-window
inner bind -n C-a send-keys X
TMUX="$SOCKET,0,0" python3 "$CLICK" bind
expect "an old key bound to something else since keeps it" "1 1" \
    "$(inner list-keys -T prefix | grep -cE "prefix +j +last-window$") $(inner list-keys -T root | grep -cE "root +C-a +send-keys X$")"
inner unbind j; inner unbind -n C-a

echo "other programs get arrow keys within the cursor's line"
# bash: type a line, move along it with tmux-jump-click, then insert X and run it.
bash_line() {
    run_pane "env -i HOME=$SCRATCH TERM=tmux-256color PS1='$ ' BASH_SILENCE_DEPRECATION_WARNING=1 bash --norc --noprofile"
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

bash_line "echo kappa $(printf 'w%02d ' $(seq 1 30))"
pick k
expect "wrapped rows count as one line" \
    "Xkappa w01 w02 w03 w04 w05 w06 w07 w08 w09 w10 w11 w12 w13 w14 w15 w16 w17 w18 w19 w20 w21 w22 w23 w24 w25 w26 w27 w28 w29 w30" \
    "$(ran)"

run_pane "env -i HOME=$SCRATCH TERM=tmux-256color PS1='$ ' BASH_SILENCE_DEPRECATION_WARNING=1 bash --norc --noprofile"
inner send-keys -t "$PANE" -l 'echo bravo'
inner send-keys -t "$PANE" Enter
sleep 0.2
inner send-keys -t "$PANE" -l 'echo alpha beta'
sleep 0.2
pick b s
expect "a place on another line is jumped to in copy mode" "1 0,1" \
    "$(inner display -p -t "$PANE" '#{pane_in_mode} #{copy_cursor_x},#{copy_cursor_y}')"
inner send-keys -t "$PANE" -X cancel
pick b a
expect "a place on the cursor's line still gets arrow keys" "alpha Xbeta" \
    "$(inner send-keys -t "$PANE" X Enter; sleep 0.3; inner capture-pane -p -t "$PANE" | sed -n 4p)"

echo "back and forward (@jump-click-back-key, @jump-click-forward-key): the jumps' history"
back() { TMUX="$SOCKET,0,0" python3 "$CLICK" back "$PANE"; sleep 0.3; }
forward() { TMUX="$SOCKET,0,0" python3 "$CLICK" forward "$PANE"; sleep 0.3; }
bash_line 'echo alpha beta gamma'
pick b; back
expect "after a jump: back where it was" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; back; back
expect "  ... and again: nothing further back" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; back; forward
expect "  ... forward: where the jump went" "alpha Xbeta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; back
expect "two jumps, back: where the second went from" "alpha Xbeta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; back; back
expect "  ... back again: where the first went from" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; back; back; forward; forward
expect "  ... forward twice: where the second went" "Xalpha beta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; back; back; forward; forward; forward
expect "  ... and again: nothing further forward" "Xalpha beta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; inner send-keys -t "$PANE" -N 2 Right; sleep 0.2; pick a; back
expect "the cursor moved after a jump: back to where the jump went" "alpha Xbeta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; inner send-keys -t "$PANE" -N 2 Right; sleep 0.2; back
expect "  ... and back from there: to where the jump went" "alpha Xbeta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; inner send-keys -t "$PANE" -N 2 Right; sleep 0.2; back; back
expect "  ... and back again: to before the jump" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; back; pick g; forward
expect "a jump after back: no forward left" "alpha beta Xgamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; inner send-keys -t "$PANE" -l 'one '; sleep 0.2; back; back
expect "text typed at the cursor: each place kept in the text" "one alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; inner send-keys -t "$PANE" End C-u; inner send-keys -t "$PANE" -l 'echo one two'; sleep 0.2; back
expect "the input's text replaced (a new prompt): the history gone" "one twoX" "$(ran)"
# The input is the same while most of its text is (edits between jumps are
# local); its blanks and marks (❯, $) do not count.
expect "the same input: by its text" "True True False False False False" "$(python3 - "$CLICK" <<'EOF'
import importlib.machinery as m, sys
sys.dont_write_bytecode = True
c = m.SourceFileLoader('c', sys.argv[1]).load_module()
print(*[c.same_input(a, b) for a, b in [
    ('$ echo alpha beta', '$ one echo alpha beta'),
    ('❯ fix the bug\n  and the test', '❯ fix the bug\n  and the tests too'),
    ('$ echo alpha beta', '$ '), ('❯ hi', '❯ '), ('$ echo alpha', '$ ls -l'),
    ('❯ fix the bug\n  and the test', '❯ write the docs')]])
EOF
)"
# A place is kept as a place in the input's text: the non-blank characters
# before it, counted from the end away from the cursor. So it stays put when
# a newline is typed (Claude Code's box grows up when its screen is full, else
# down), when the input moves as a whole, and when its text wraps anew.
expect "  ... a newline typed, the input moved, its text wrapped anew: each place where it was" \
    "[(6, 10), (4, 2)] [(7, 10), (5, 2)] [(4, 10), (3, 2)] [(6, 14), (5, 2)] [(0, 13)]" "$(python3 - "$CLICK" <<'EOF'
import importlib.machinery as m, sys
sys.dont_write_bytecode = True
c = m.SourceFileLoader('c', sys.argv[1]).load_module()
was = (5, ['❯ fix the bug', '  and the test'])          # (first row, rows)
kept = c.anchored(was, [c.place_of(was, (6, 10)), c.place_of(was, (5, 2))],   # test, fix
                  c.place_of(was, (5, 13)))               # the cursor: after bug
for now in [(4, ['❯ fix the bug', '  ', '  and the test']),
            (5, ['❯ fix the bug', '  ', '  and the test']),
            (3, ['❯ fix the bug', '  and the test']),
            (5, ['❯ fix the', '  bug and the test'])]:
    print([c.cell_of(now, p) for p in c.placed(now, kept)], end=' ')
line = (0, ['$ echo alpha'])                              # after a space typed
print([c.cell_of(line, p) for p in c.placed(line, c.anchored(line, [c.place_of(line, (0, 13))], c.place_of(line, (0, 0))))])
EOF
)"
expect "a key's bytes in the popup: as tmux passes them on" "1b07 1b47 1b67 07 none none" "$(python3 - "$CLICK" <<'EOF'
import importlib.machinery as m, sys
sys.dont_write_bytecode = True
c = m.SourceFileLoader('c', sys.argv[1]).load_module()
print(*[c.key_bytes(k).hex() if c.key_bytes(k) else 'none' for k in ['C-M-S-g', 'M-G', 'M-g', 'C-g', 'User2', 'F5']])
EOF
)"
# \e[103;7u is C-M-g to tmux, which passes it on to a popup as Esc C-g (with
# Shift too, tmux 3.4 passes it on as nothing).
inner set -g @jump-click-forward-key C-M-g
bash_line 'echo alpha beta gamma'
pick b; pick $'\e[103;7u'
expect "in the popup, the forward key: the history's places; one: gone to at once" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; pick $'\e[103;7u' s
expect "  ... several: labelled, the nearest back first" "alpha beta gammaX" "$(ran)"
bash_line 'echo alpha beta gamma'
pick b; pick a; back; pick $'\e[103;7u' s
expect "  ... then forward" "Xalpha beta gamma" "$(ran)"
bash_line 'echo alpha beta gamma'
pick $'\e[103;7u'
expect "  ... none: nothing" "alpha beta gammaX" "$(ran)"
inner set -gu @jump-click-forward-key
run_pane "python3 $SCRATCH/editor.py $SCRATCH/rec.log clicks 'alpha beta gamma'"
pick b; back
expect "  ... in a program that takes clicks" "1 18" "$(inner display -p -t "$PANE" '#{cursor_y} #{cursor_x}' | awk '{print $1+1, $2}')"
bash_line 'echo alpha beta gamma'          # respawned: a new program, no history
back
expect "  ... no jump yet: nothing" "alpha beta gammaX" "$(ran)"
inner set -g @jump-click-mark-keys 'C-a C-e'
inner set -g @jump-click-back-key 'M-g'
inner set -g @jump-click-forward-key 'M-h'
inner run-shell "python3 $CLICK bind"
bash_line 'echo alpha beta'
tmux -L "$OUTER" send-keys C-a; sleep 0.3
expect "@jump-click-mark-keys: the key still does what it did (bash: after its prompt)" "1 2" "$(inner display -p -t "$PANE" '#{cursor_y} #{cursor_x}' | awk '{print $1+1, $2}')"
tmux -L "$OUTER" send-keys M-g; sleep 0.5
expect "  ... and back (the @jump-click-back-key) goes to before it" "alpha betaX" "$(ran)"
bash_line 'echo alpha beta'
tmux -L "$OUTER" send-keys C-a; sleep 0.3
tmux -L "$OUTER" send-keys M-g; sleep 0.5
tmux -L "$OUTER" send-keys M-h; sleep 0.5
expect "  ... and forward (the @jump-click-forward-key) to where the key went" "Xecho alpha beta" "$(inner send-keys -t "$PANE" X Enter; sleep 0.3; inner capture-pane -p -t "$PANE" -J | sed -n 1p | sed 's/^\$ //; s/ *$//')"
bash_line 'echo alpha beta'
tmux -L "$OUTER" send-keys C-a; sleep 0.3
inner send-keys -t "$PANE" -N 5 Right; inner send-keys -t "$PANE" -l 'new '; sleep 0.2
tmux -L "$OUTER" send-keys M-g; sleep 0.5
tmux -L "$OUTER" send-keys M-g; sleep 0.5
expect "  ... text typed before the place: back to it still (the line's end; moved away: twice)" "new alpha betaX" "$(ran)"
bash_line 'echo alpha beta'
inner send-keys -t "$PANE" -N 4 Left; sleep 0.2
tmux -L "$OUTER" send-keys C-e; sleep 0.3
inner send-keys -t "$PANE" -l ' more'; sleep 0.2
tmux -L "$OUTER" send-keys M-g; sleep 0.5
expect "  ... text typed after it: back to it still" "alpha Xbeta more" "$(ran)"
bash_line 'echo alpha beta gamma'
pick a; inner send-keys -t "$PANE" -l 'one '; sleep 0.2; back
expect "  ... after a jump-click too" "one alpha beta gammaX" "$(ran)"
run_pane "env -i HOME=$SCRATCH TERM=tmux-256color PS1='$ ' BASH_SILENCE_DEPRECATION_WARNING=1 bash --norc --noprofile"
inner send-keys -t "$PANE" -l 'echo bravo'; inner send-keys -t "$PANE" Enter; sleep 0.2
inner send-keys -t "$PANE" -l 'echo alpha beta'; sleep 0.2
pick b s; back
expect "after a jump in copy mode: copy mode left" "0" "$(inner display -p -t "$PANE" '#{pane_in_mode}')"
inner set -gu @jump-click-mark-keys; inner set -gu @jump-click-back-key; inner set -gu @jump-click-forward-key
inner run-shell "python3 $CLICK bind"
expect "  ... unset: the keys unbound" "" "$(inner list-keys -T root | grep -E ' (C-a|C-e|M-g|M-h) ' || true)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
