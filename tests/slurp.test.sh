#!/usr/bin/env bash
# Tests for bin/tmux-slurp: with the cursor inside a pair, C-) and C-( move
# its closer or opener out over the next word (slurp), M-) and M-( move it
# back in over the last word (barf). A scratch tmux server runs a one-line
# editor; its client runs in a pane of a second scratch server, and keys
# typed there reach the first as from a terminal, through its bindings. The
# editor's line is read back. Needs tmux 3.4 or newer and python3.
#
#   bash tests/slurp.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-sl.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
export TMPDIR="$SCRATCH"
unset TMUX
cleanup() {
    TMUX_TMPDIR="$SCRATCH/o" tmux kill-server 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    rm -rf "$SCRATCH"
}
trap cleanup EXIT
SL="$HERE/../bin/tmux-slurp"

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}

# A one-line editor: "> " and what is typed, which it also writes to a file,
# with the cursor's place marked |. Typing goes in at the cursor; Backspace
# deletes before it; Left and Right move it, not past either end. With a
# second argument, it takes that many seconds over each redraw, as a slow
# program does.
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
PANE=$(tmux display -p '#{pane_id}')
mkdir -p "$SCRATCH/o"
TMUX_TMPDIR="$SCRATCH/o" tmux -f /dev/null new-session -d -x 80 -y 6 "env -u TMUX TMUX_TMPDIR=$SCRATCH tmux attach"
TMUX_TMPDIR="$SCRATCH/o" tmux set -s escape-time 0
sleep 0.8
# The editor's program, as tmux names it (python3, python3.12, Python).
tmux set -g @slurp-commands "$(tmux display -p -t "$PANE" '#{pane_current_command}')"
python3 "$SL" bind

line() { cat "$SCRATCH/line"; }
# at TEXT [DELAY] — restart the editor (DELAY seconds a redraw) with TEXT
# typed, the cursor where TEXT has |.
at() {
    : > "$SCRATCH/line"
    tmux respawn-pane -k -t "$PANE" "python3 $SCRATCH/editor.py $SCRATCH/line ${2:-}"
    sleep 0.4
    local text="${1/|/}" back="${1#*|}"
    tmux send-keys -t "$PANE" -l -- "$text"
    [ -z "$back" ] || tmux send-keys -t "$PANE" -N "${#back}" Left
    local i
    for i in $(seq 50); do [ "$(line)" = "$1" ] && return; sleep 0.05; done
    echo "  (setup: want '$1', got '$(line)')"
}
# The keys as a terminal sends them: C-( and C-) as CSI u (Ghostty, kitty),
# M-( and M-) as ESC and the character.
press() {
    local seq
    case "$1" in
        'C-(') seq=$'\e[40;5u' ;; 'C-)') seq=$'\e[41;5u' ;;
        'M-(') seq=$'\e(' ;; 'M-)') seq=$'\e)' ;;
    esac
    TMUX_TMPDIR="$SCRATCH/o" tmux send-keys -l -- "$seq"
    sleep 0.6
}

echo "slurp forward: C-)"
at '(foo|) bar baz'; press 'C-)'
expect "the closer moves past the next word" '(foo| bar) baz' "$(line)"
press 'C-)'
expect "  ... and again" '(foo| bar baz)' "$(line)"
press 'C-)'
expect "  ... no word left: nothing" '(foo| bar baz)' "$(line)"
at '[|]hello there'; press 'C-)'
expect "a word right after the closer (a pair typed before it)" '[|hello] there' "$(line)"
at '"hi|" there'; press 'C-)'
expect "a quote" '"hi| there"' "$(line)"
at '(x|) [a b] c'; press 'C-)'
expect "a bracketed group is one word" '(x| [a b]) c' "$(line)"
at '(a "b|" c) d'; press 'C-)'
expect "the innermost pair" '(a "b| c") d' "$(line)"
press 'C-)'
expect "  ... not past the pair around it" '(a "b| c") d' "$(line)"
at '"don'"'"'t| stop" now'; press 'C-)'
expect "an apostrophe is no quote" '"don'"'"'t| stop now"' "$(line)"
at '(日本|) 語 x'; press 'C-)'
expect "wide characters" '(日本| 語) x' "$(line)"
at '(foo|) bar, baz'; press 'C-)'
expect "punctuation after the word: a step of its own" '(foo| bar), baz' "$(line)"
press 'C-)'
expect "  ... then the punctuation" '(foo| bar,) baz' "$(line)"
at '(foo|) "bar"... baz'; press 'C-)'
expect "  ... after a pair in the word too" '(foo| "bar")... baz' "$(line)"

echo "slurp backward: C-("
at 'foo bar (|baz)'; press 'C-('
expect "the opener moves before the word before" 'foo (bar |baz)' "$(line)"
press 'C-('
expect "  ... and again" '(foo bar |baz)' "$(line)"
press 'C-('
expect "  ... not into the prompt before the input" '(foo bar |baz)' "$(line)"

at 'hello""|'; press 'C-('
expect "right after an empty pair (a quote after a word, hello\"\"|): that pair" '"hello"|' "$(line)"
at 'say hello``|'; press 'C-('
expect "  ... backticks" 'say `hello`|' "$(line)"
at 'a ()|'; press 'C-('
expect "  ... brackets, the space kept as any slurp keeps it" '(a )|' "$(line)"
at '(x hello""|)'; press 'C-('
expect "  ... within another pair: that one, not past its opener" '(x "hello"|)' "$(line)"
press 'C-('
expect "  ... and again, inside now" '("x hello"|)' "$(line)"
at 'hello""| x'; press 'C-)'
expect "  ... only backward: C-) there does nothing" 'hello""| x' "$(line)"

echo "barf forward: M-)"
at '(foo bar| baz)'; press 'M-)'
expect "the closer moves before the last word" '(foo bar|) baz' "$(line)"
at '(foo ba|r)'; press 'M-)'
expect "the cursor in that word stays in it" '(foo) ba|r' "$(line)"
at '(foo|)'; press 'M-)'
expect "one word: nothing" '(foo|)' "$(line)"
at '(foo bar|,)'; press 'M-)'
expect "punctuation after the last word: a step of its own" '(foo bar|),' "$(line)"
press 'M-)'
expect "  ... then the word" '(foo) bar|,' "$(line)"
at '(foo|!)'; press 'M-)'
expect "  ... one word and its punctuation: the punctuation" '(foo|)!' "$(line)"

echo "barf backward: M-("
at '(foo bar| baz)'; press 'M-('
expect "the opener moves after the first word" 'foo (bar| baz)' "$(line)"
at '(f|oo bar)'; press 'M-('
expect "the cursor in that word stays in it" 'f|oo (bar)' "$(line)"
at '(foo, bar| baz)'; press 'M-('
expect "the word's punctuation goes with it (backward)" 'foo, (bar| baz)' "$(line)"
at 'foo, (|bar)'; press 'C-('
expect "  ... slurp backward too" '(foo, |bar)' "$(line)"

echo "the cursor on the opener (a block cursor shows it there): that pair"
at '|"hello" world'; press 'C-)'
expect "slurp forward" '|"hello world"' "$(line)"
at 'foo |"bar"'; press 'C-('
expect "slurp backward: the cursor stays on the opener" '|"foo bar"' "$(line)"
at '|(foo bar)'; press 'M-)'
expect "barf forward" '|(foo) bar' "$(line)"
at '|(foo bar)'; press 'M-('
expect "barf backward: the cursor stays on the opener" 'foo |(bar)' "$(line)"
at '(a |"b" c) d'; press 'C-)'
expect "  ... within another pair: the one at the cursor" '(a |"b c") d' "$(line)"

echo "nothing around the cursor"
at 'foo| bar'; press 'C-)'
expect "outside any pair: nothing" 'foo| bar' "$(line)"

echo "a slow program"
at '(a|) b c' 0.04; press 'C-)'; press 'C-)'
expect "each step waits for the screen" '(a| b c)' "$(line)"

echo "elsewhere"
tmux set -g @slurp-commands 'nothing-runs-this'
python3 "$SL" bind
at 'x|'; press 'M-('
expect "in other programs the key goes on as it is" 'x(|' "$(line)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
