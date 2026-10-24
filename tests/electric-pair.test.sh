#!/usr/bin/env bash
# Tests for bin/tmux-electric-pair: typing an opener types its pair, a closer
# steps over the one after the cursor, Backspace between an empty pair takes
# both. A scratch tmux server runs a one-line editor; the script is run on its
# pane as the bindings run it, and the editor's line is read back. Needs tmux
# and python3.
#
#   bash tests/electric-pair.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EP="$HERE/../bin/tmux-electric-pair"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-ep.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
unset TMUX
trap 'tmux kill-server 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}

# A one-line editor: "> " and what is typed, which it also writes to a file,
# with the cursor's place marked |. Typing goes in at the cursor; Backspace
# deletes before it; Left and Right move it.
cat > "$SCRATCH/editor.py" <<'EOF'
import os, re, sys, tty, unicodedata
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
    cells = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in text[:pos])
    os.write(1, ('\r\x1b[K> ' + text + '\r\x1b[' + str(2 + cells) + 'C').encode())
    open(sys.argv[1], 'w').write(text[:pos] + '|' + text[pos:])
EOF

tmux -f /dev/null new-session -d -x 80 -y 5 'sleep 600'
tmux set -s escape-time 0
PANE=$(tmux display -p '#{pane_id}')

editor() {
    : > "$SCRATCH/line"
    tmux respawn-pane -k -t "$PANE" "python3 $SCRATCH/editor.py $SCRATCH/line"
    sleep 0.4
}
typed() { tmux send-keys -t "$PANE" -l -- "$1"; sleep 0.15; }
# key C... — press each character (or BSpace) as the binding does.
key() { for k in "$@"; do python3 "$EP" key "$k" "$PANE"; done; sleep 0.1; }
line() { cat "$SCRATCH/line"; }

echo "openers"
editor; key '('
expect "( types () with the cursor between" '(|)' "$(line)"
editor; key '[' '{'
expect "nested" '[{|}]' "$(line)"
editor; typed 'f'; key '('
expect "after a word too: f(|)" 'f(|)' "$(line)"
editor; typed 'word'; tmux send-keys -t "$PANE" Left Left Left Left; sleep 0.1; key '('
expect "before a word: ( alone" '(|word' "$(line)"

echo "closers"
editor; key '(' ')'
expect ") over the ) after the cursor steps over it" '()|' "$(line)"
editor; key '('; typed 'ab'; key ')'
expect "  ... after typing inside" '(ab)|' "$(line)"
editor; key ')'
expect ") with none after: typed" ')|' "$(line)"
editor; key '(' ']'
expect "a different closer: typed" '(]|)' "$(line)"

echo "quotes"
editor; key '"'
expect '" types ""' '"|"' "$(line)"
editor; key '"'; typed 'hi'; key '"'
expect '" over the " after the cursor steps over it' '"hi"|' "$(line)"
editor; typed "don"; key "'"
expect "' after a letter: alone (don't)" "don'|" "$(line)"
editor; typed 'a \'; key '"'
expect '" after a backslash: alone' 'a \"|' "$(line)"
editor; key '`'
expect '` types ``' '`|`' "$(line)"

echo "Backspace"
editor; key '(' BSpace
expect "between an empty pair: both go" '|' "$(line)"
editor; key '"' BSpace
expect "  ... quotes too" '|' "$(line)"
editor; key '('; typed 'a'; key BSpace
expect "otherwise one character" '(|)' "$(line)"
editor; typed 'ab'; key BSpace
expect "  ... as anywhere" 'a|' "$(line)"

echo "wide characters"
editor; typed '日本'; key '(' ')'
expect "after wide characters" '日本()|' "$(line)"

echo "@electric-pair-pairs"
tmux set -g @electric-pair-pairs '()'
editor; key '"'
expect "a character not in the pairs is typed as it is" '"|' "$(line)"
editor; key '('
expect "  ... those in them pair" '(|)' "$(line)"
tmux set -gu @electric-pair-pairs

echo "bind"
bound() { tmux list-keys -T root | grep -F 'tmux-electric-pair key' | awk '{print $4}' | sed 's/^\\//' | LC_ALL=C sort | tr '\n' ' '; }
python3 "$EP" bind
expect "binds the pairs and BSpace" "\" ' ( ) BSpace [ ] \` { } " "$(bound)"
expect "  ... in the programs named" 1 "$(tmux list-keys -T root BSpace | grep -c 'claude|codex|pi|node|agy|gemini')"
tmux set -g @electric-pair-pairs '()'
python3 "$EP" bind
expect "rebinding with fewer pairs unbinds the rest" '( ) BSpace ' "$(bound)"
tmux set -g @electric-pair-commands ''
python3 "$EP" bind
expect "@electric-pair-commands '': nothing bound" '' "$(bound)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
