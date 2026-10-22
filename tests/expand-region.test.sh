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
    rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SERVER"     # tmux leaves it when the server exits
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
    # #{selection_active} too: tmux 3.5 counts a one-character selection as not present.
    if [ "$(t display -p -t "$PANE" '#{selection_present}#{selection_active}')" != 00 ]; then
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
expect "word, accessor, path, path:line, brackets" \
    'app|app.py|src/app.py|src/app.py:42|src/app.py:42, "quoted text"|(src/app.py:42, "quoted text")' \
    "$(steps expand expand expand expand expand expand)"

show 'see (src/app.py:42, "quoted text") here'
at 0 21
expect "quotes, inside then with" \
    'quoted|quoted text|"quoted text"|src/app.py:42, "quoted text"' \
    "$(steps expand expand expand expand)"

show 'if m.start() <= p: (see f(x)).'
at 0 6
expect "a method call: the accessor chain, then its arguments" \
    'start|m.start|m.start()' "$(steps expand expand expand)"
t send -t "$PANE" -X cancel
t copy-mode -t "$PANE"
at 0 24
expect "  ... and a call in brackets" 'f|f(x)' "$(steps expand expand)"

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

# first REGION ROW COL TEXT... — the first N steps from (ROW, COL) of TEXT.
first() {
    local n=$1 row=$2 col=$3; shift 3
    show "$@"
    at "$row" "$col"
    local actions=() i
    for i in $(seq "$n"); do actions+=(expand); done
    steps "${actions[@]}"
}
# reaches REGION ROW COL TEXT... — whether expanding from (ROW, COL) ever
# selects exactly REGION.
reaches() {
    local want=$1; shift
    local all got
    all=$(first 8 "$@")
    local IFS='|'
    for got in $all; do [ "$got" = "$want" ] && { echo yes; return; }; done
    echo no
}

expect "a word stops at _ and -, a symbol does not" 'bar|foo_bar-baz' \
    "$(first 2 0 4 'foo_bar-baz qux')"
expect "a symbol with its prefix: \$HOME" 'HOME|$HOME' "$(first 2 0 6 'echo $HOME and --yolo')"
expect "  ... and --yolo" 'yolo|--yolo' "$(first 2 0 18 'echo $HOME and --yolo')"
expect "a call through an accessor chain" 're|re.finditer|re.finditer(r"\S+", text)' \
    "$(first 3 0 4 'x = re.finditer(r"\S+", text)')"
expect "a path" yes "$(reaches '~/dev/ppi/config' 0 12 'cd ~/dev/ppi/config, then')"
expect "a path with a line and column" yes "$(reaches 'lib/run.sh:12:3' 0 7 'at lib/run.sh:12:3.')"
expect "a URL of any scheme" yes "$(reaches 'sess://claude/abc-123?at=4' 0 15 'open sess://claude/abc-123?at=4, then')"
expect "an https URL without the sentence's full stop" yes \
    "$(reaches 'https://emacsredux.com/blog/x/' 0 20 'see https://emacsredux.com/blog/x/.')"
expect "an email address" yes "$(reaches 'bob.smith@example.com' 0 16 'mail bob.smith@example.com now')"
expect "an apostrophe does not open a quote" "x|x y|'x y'" "$(first 3 0 7 "don't 'x y' ok")"
expect "an escaped quote stays inside the string" 'a|a \"b\" c|"a \"b\" c"' \
    "$(first 3 0 5 'say "a \"b\" c" end')"
expect "a bracket inside a string does not pair" 'x|"(", x|("(", x)|f("(", x)' \
    "$(first 4 0 7 'f("(", x)')"
expect "a comment block" yes "$(reaches '# one
# two' 0 2 '# one' '# two' 'code')"
expect "a sentence" yes "$(reaches 'Second here, more.' 0 18 'First one. Second here, more. Third.')"
expect "from whitespace, the next word" 'beta' "$(first 1 0 6 'alpha   beta')"

echo "rules file"
cat > "$SCRATCH/rules" <<'EOF'
# drop a default, add two
-word
pid   regex  \d+
kv    regex  (?P<key>\w+)=(?P<val>\w+)
EOF
t set -g @expand-region-rules "$SCRATCH/rules"
expect "a dropped default is not used" 'foo_bar' "$(first 1 0 4 'foo_bar')"
expect "a regex rule of its own" '12345' "$(first 1 0 6 'pid 12345 up')"
expect "named groups are regions too" 'val|key=val' "$(first 2 0 8 'a key=val b')"
rules=$(TMUX="$SOCKET,0,0" python3 "$EXPAND" rules)
expect "rules lists what is in effect" "kv pid no-word" \
    "$(grep -qw kv <<<"$rules" && echo -n 'kv '; grep -qw pid <<<"$rules" && echo -n 'pid '; grep -qE '^word ' <<<"$rules" || echo -n no-word)"
t set -gu @expand-region-rules

echo "shrinking"
show 'see (src/app.py:42, "quoted text") here'
at 0 9
expect "shrink retraces the steps, then clears" \
    'app|app.py|src/app.py|app.py|app|' \
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
