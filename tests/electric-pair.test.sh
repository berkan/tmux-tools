#!/usr/bin/env bash
# Tests for bin/tmux-electric-pair: typing an opener types its pair, a closer
# steps over the one after the cursor, Backspace between an empty pair takes
# both. A scratch tmux server runs a one-line editor; its client runs in a
# pane of a second scratch server, and keys typed there reach the first as
# from a terminal, through its bindings. The editor's line is read back.
# Needs tmux 3.4 or newer and python3.
#
#   bash tests/electric-pair.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-ep.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
export TMPDIR="$SCRATCH"
unset TMUX
cleanup() {
    TMUX_TMPDIR="$SCRATCH/o" tmux kill-server 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
# The bindings run a copy, so that it can be taken away to show which keys
# need no process.
EP="$SCRATCH/bin/tmux-electric-pair"
mkdir -p "$SCRATCH/bin"
cp "$HERE/../bin/tmux-electric-pair" "$EP"

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}

# A one-line editor: "> " and what is typed, which it also writes to a file,
# with the cursor's place marked |. Typing goes in at the cursor; Backspace
# deletes before it; Left and Right move it. With a second argument, it takes
# that many seconds over each redraw, as a slow program does.
cat > "$SCRATCH/editor.py" <<'EOF'
import os, re, sys, time, tty, unicodedata
tty.setraw(0)
os.write(1, b'\x1b[2J\x1b[H> ')
text, pos = '', 0
while True:
    data = os.read(0, 256).decode('utf-8', 'replace')
    for m in re.finditer(r'\x1b\[(C|D)|.', data, re.S):
        key, ch = m.group(1), m.group()
        if key:
            pos = max(0, min(len(text), pos + (1 if key == 'C' else -1)))
        elif ch == '\x7f':
            if pos:
                text, pos = text[:pos - 1] + text[pos:], pos - 1
        elif ch.isprintable():
            text, pos = text[:pos] + ch + text[pos:], pos + 1
    time.sleep(float(sys.argv[2]) if sys.argv[2:] else 0)
    cells = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text[:pos])
    os.write(1, ('\r\x1b[K> ' + text + '\r\x1b[' + str(2 + cells) + 'C').encode())
    open(sys.argv[1], 'w').write(text[:pos] + '|' + text[pos:])
EOF

tmux -f /dev/null new-session -d -x 80 -y 5 "python3 $SCRATCH/editor.py $SCRATCH/line"
tmux set -s escape-time 0
# Keys that come together are a paste to tmux, which skips the bindings for
# them; here they are keys typed back to back.
tmux set -s assume-paste-time 0
PANE=$(tmux display -p '#{pane_id}')
mkdir -p "$SCRATCH/o"
TMUX_TMPDIR="$SCRATCH/o" tmux -f /dev/null new-session -d -x 80 -y 6 "env -u TMUX TMUX_TMPDIR=$SCRATCH tmux attach"
TMUX_TMPDIR="$SCRATCH/o" tmux set -s escape-time 0
sleep 0.8
# The editor's program, as tmux names it (python3, python3.12, Python).
tmux set -g @electric-pair-commands "$(tmux display -p -t "$PANE" '#{pane_current_command}')"
python3 "$EP" bind

# editor [DELAY] — restart the pane with the editor, DELAY seconds a redraw.
editor() {
    : > "$SCRATCH/line"
    tmux respawn-pane -k -t "$PANE" "python3 $SCRATCH/editor.py $SCRATCH/line ${1:-}"
    sleep 0.4
}
# press K... — the keys typed in the client's terminal: characters, or key
# names (BSpace, Left).
press() { TMUX_TMPDIR="$SCRATCH/o" tmux send-keys -- "$@"; }
# key K... — each key as typed, one at a time.
key() { for k in "$@"; do press "$k"; sleep 0.05; done; sleep 0.15; }
# fast K... — all in one go, with no pause between them; then wait until
# the line stays as it is.
fast() {
    press "$@"
    local a b=x
    while a=$(line) && [ "$a" != "$b" ]; do b=$a; sleep 0.6; done
}
line() { cat "$SCRATCH/line"; }

echo "openers"
editor; key '('
expect "( types () with the cursor between" '(|)' "$(line)"
editor; key '[' '{'
expect "nested" '[{|}]' "$(line)"
editor; key f '('
expect "after a word too: f(|)" 'f(|)' "$(line)"
editor; key w o r d Left Left Left Left '('
expect "before a word: ( alone" '(|word' "$(line)"
editor; key a '\' '('
expect "after a backslash: ( alone" 'a\(|' "$(line)"

echo "closers"
editor; key '(' ')'
expect ") over the ) after the cursor steps over it" '()|' "$(line)"
editor; key '(' a b ')'
expect "  ... after typing inside" '(ab)|' "$(line)"
editor; key ')'
expect ") with none after: typed" ')|' "$(line)"
editor; key '(' ']'
expect "a different closer: typed" '(]|)' "$(line)"

echo "quotes"
editor; key '"'
expect '" types ""' '"|"' "$(line)"
editor; key '"' h i '"'
expect '" over the " after the cursor steps over it' '"hi"|' "$(line)"
editor; key d o n "'"
expect "' after a letter: alone (don't)" "don'|" "$(line)"
editor; key a ' ' '\' '"'
expect '" after a backslash: alone' 'a \"|' "$(line)"
editor; key '`'
expect '` types ``' '`|`' "$(line)"

echo "Backspace"
editor; key '(' BSpace
expect "between an empty pair: both go" '|' "$(line)"
editor; key '"' BSpace
expect "  ... quotes too" '|' "$(line)"
editor; key '(' a BSpace
expect "otherwise one character" '(|)' "$(line)"
editor; key a b BSpace
expect "  ... as anywhere" 'a|' "$(line)"

echo "wide characters"
editor; key 日 本 '(' ')'
expect "after wide characters" '日本()|' "$(line)"

echo "after dabbrev closed its completion"
# As dabbrev leaves "hel + Tab: "hello" , the cursor after the space.
editor; key '"' h e l l o '"' ' '
tmux set -p -t "$PANE" @dabbrev-closed "$(tmux display -p -t "$PANE" '#{cursor_x} #{cursor_y}') \""
key '"'
expect 'the closer is not typed again' '"hello" |' "$(line)"
key '"'
expect '  ... but a second time it is' '"hello" "|"' "$(line)"
editor; key '(' h i ')' ' '
tmux set -p -t "$PANE" @dabbrev-closed "$(tmux display -p -t "$PANE" '#{cursor_x} #{cursor_y}') )"
key Left ')'
expect '  ... only where dabbrev left the cursor' '(hi))| ' "$(line)"

echo "typed fast"
editor; fast '(' a ')' ' ' '"' b '"' ' ' d o n "'" t ' ' '[' BSpace
expect "keys in one go stay in order, each reading the screen as it is" '(a) "b" don'"'"'t |' "$(line)"
# Claude Code takes 10-30 ms to show a key; this one 40.
for i in 1 2 3; do
    editor 0.04; fast '(' a ')' ' ' '"' b '"' ' ' d o n "'" t ' ' '[' BSpace '(' '(' x ')' ')'
    expect "  ... when the program is slow to show them ($i)" '(a) "b" don'"'"'t ((x))|' "$(line)"
done

echo "no process for the common keys"
mv "$EP" "$EP.away"
editor; key a b BSpace
expect "BSpace on text" 'a|' "$(line)"
editor; key a ')'
expect "a closer with none after" 'a)|' "$(line)"
editor; key x y Left '('
expect "an opener before a letter" 'x(|y' "$(line)"
mv "$EP.away" "$EP"
editor; key '(' a
mv "$EP" "$EP.away"
key ')'
expect "a closer stepping over" '(a)|' "$(line)"
mv "$EP.away" "$EP"
editor; key '(' a b c
mv "$EP" "$EP.away"
key BSpace BSpace
expect "BSpace on text inside a pair" '(a|)' "$(line)"
mv "$EP.away" "$EP"
key BSpace BSpace
expect "  ... and on into the empty pair: both go" '|' "$(line)"
editor; key '(' '(' BSpace BSpace
expect "nested empty pairs, one after the other" '|' "$(line)"

echo "@electric-pair-pairs"
tmux set -g @electric-pair-pairs '()'
python3 "$EP" bind
editor; key '"'
expect "a character not in the pairs is typed as it is" '"|' "$(line)"
editor; key '('
expect "  ... those in them pair" '(|)' "$(line)"
tmux set -g @electric-pair-pairs '<>'
python3 "$EP" bind
editor; key '<' '>'
expect "  ... any pair: <>" '<>|' "$(line)"
tmux set -gu @electric-pair-pairs

echo "bind"
bound() { tmux list-keys -T root | grep -F 'electric-pair' | awk '{print $4}' | sed 's/^\\//' | LC_ALL=C sort | tr '\n' ' '; }
python3 "$EP" bind
expect "binds the pairs and BSpace" "\" ' ( ) BSpace [ ] \` { } " "$(bound)"
tmux set -g @electric-pair-pairs '()'
python3 "$EP" bind
expect "rebinding with fewer pairs unbinds the rest" '( ) BSpace ' "$(bound)"
tmux set -g @electric-pair-commands ''
python3 "$EP" bind
expect "@electric-pair-commands '': nothing bound" '' "$(bound)"
tmux set -g @electric-pair-commands 'zsh'
python3 "$EP" bind
editor; key '(' BSpace '"'
expect "in another program: keys as they are" '"|' "$(line)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
