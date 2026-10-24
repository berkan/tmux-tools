#!/usr/bin/env bash
# Tests for config/tmux-dabbrev: completing the word before the cursor from the
# words on the pane's screen. A scratch tmux server runs a one-line editor
# under some lines of text; the script is run on its pane as the M-/ and Tab
# bindings run it, and the editor's line is read back. Needs tmux and python3,
# no Docker.
#
#   bash tests/dabbrev.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DAB="$HERE/../bin/tmux-dabbrev"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-dabbrev-test.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"         # the server's socket goes with the scratch dir
export TMPDIR="$SCRATCH/tmp"          # and the script's state files
mkdir -p "$TMPDIR"
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

# A one-line editor: the lines given, then "> " and what is typed, which it
# also writes to a file (the screen cannot show a trailing space), and the
# cursor's place in it to another. Typing goes in at the cursor; Backspace
# deletes before it; Left and Right move it; a bracketed paste goes in whole,
# its line breaks shown as ⏎; a Tab is logged, not inserted.
cat > "$SCRATCH/editor.py" <<'EOF'
import os, re, sys, tty, unicodedata
log = open(sys.argv[1], 'a')
tty.setraw(0)
os.write(1, ('\x1b[?2004h\x1b[2J\x1b[H' + ''.join(l + '\r\n' for l in sys.argv[2:]) + '> ').encode())
text, pos, pasting = '', 0, False
while True:
    data = os.read(0, 256).decode('utf-8', 'replace')
    for m in re.finditer(r'\x1b\[(200~|201~|C|D)|.', data, re.S):
        key, ch = m.group(1), m.group()
        if key in ('200~', '201~'):
            pasting = key == '200~'
        elif key in ('C', 'D'):
            pos = max(0, min(len(text), pos + (1 if key == 'C' else -1)))
        elif ch == '\t':
            log.write('TAB\n'); log.flush()
        elif ch == '\x7f':
            if pos:
                text, pos = text[:pos - 1] + text[pos:], pos - 1
        elif ch.isprintable() or (pasting and ch == '\r'):
            ch = '\n' if ch == '\r' else ch
            text, pos = text[:pos] + ch + text[pos:], pos + 1
    shown = text.replace('\n', '⏎')
    cells = sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in shown[:pos])
    os.write(1, ('\r\x1b[K> ' + shown + '\r\x1b[' + str(2 + cells) + 'C').encode())
    open(sys.argv[1] + '.text', 'w').write(text)
    open(sys.argv[1] + '.pos', 'w').write(str(pos))
EOF

# Wide enough that an absolute path under the scratch dir is on one row.
tmux -f /dev/null new-session -d -x 200 -y 12 'sleep 600'
tmux set -s escape-time 0
# Reading order, so that the tests of the rest do not hang on the order
# being tried out (@dabbrev-order); "orders" tests each.
tmux set -g @dabbrev-order top
PANE=$(tmux display -p '#{pane_id}')

# editor LINE... — restart the pane with the editor under LINEs, in $CWD.
ROW=0
CWD="$SCRATCH"
editor() {
    : > "$SCRATCH/tabs.log"; : > "$SCRATCH/tabs.log.text"
    ROW=$#
    tmux respawn-pane -k -t "$PANE" -c "$CWD" "python3 $SCRATCH/editor.py $SCRATCH/tabs.log $(printf '%q ' "$@")"
    sleep 0.4
}
typed() { tmux send-keys -t "$PANE" -l -- "$1"; sleep 0.2; }
dab() { for a in "$@"; do HOME="$SCRATCH/files" python3 "$DAB" "$a" "$PANE"; done; sleep 0.1; }
line() { cat "$SCRATCH/tabs.log.text"; }
cursor() { cat "$SCRATCH/tabs.log.pos"; }
tabs() { grep -c TAB "$SCRATCH/tabs.log" || true; }

echo "M-/ (expand)"
editor 'alpha beta gamma'
typed 'ga'; dab expand
expect "completes the word before the cursor, and a space" "gamma " "$(line)"

editor 'garden two' 'gamma one'
typed 'ga'; dab expand
expect "the match highest on screen comes first" "garden " "$(line)"
dab expand
expect "again: the next match replaces it" "gamma " "$(line)"
dab expand
expect "past the last: back to what was typed" ga "$(line)"
dab expand
expect "  ... and round again" "garden " "$(line)"

editor 'gamma gamma garden'
typed 'ga'; dab expand expand expand
expect "each word once" ga "$(line)"

editor 'Gamma garden'
typed 'Ga'; dab expand
expect "a capital in what was typed matches case" "Gamma " "$(line)"
editor 'Gamma'
typed 'ga'; dab expand
expect "lower case matches either, the word goes in as on screen" "Gamma " "$(line)"

editor 'ga'
typed 'ga'; dab expand
expect "the word itself is no completion" ga "$(line)"

editor 'see src/tmux-dabbrev.py now'
typed 'src/tm'; dab expand
expect "a word may hold / . - inside" "src/tmux-dabbrev.py " "$(line)"

editor '日本語 gamma'
typed '日本 ga'; dab expand
expect "wide characters before the word" '日本 gamma ' "$(line)"

echo "context"
editor 'Recorder/2026 more' 'a long recording here'
typed 'long re'; dab expand
expect "a match after the words typed before it beats one higher up" 'long recording ' "$(line)"
editor 'Recorder/2026 more' 'a long recording here'
typed 're'; dab expand
expect "  ... without them, the higher one" 'Recorder/2026 ' "$(line)"
editor 'the long red' 'a long recording' 'red'
typed 'a long re'; dab tab
expect "more words before it matching beats fewer" 'a long recording ' "$(line)"
editor 'long' 'recording here' 'Recorder/2026 more'
typed 'long re'; dab tab tab
expect "  ... across a line break; Tab goes on from that match" 'long recording here ' "$(line)"

echo "a full screen"
# Every word a candidate, each with the rest of the screen after it: far more
# state than one tmux command can carry (about 16 KB).
words=()
for r in $(seq 10); do
    l=''; for c in $(seq 8); do l+="word$r$c "; done; words+=("$l")
done
editor "${words[@]}"
typed 'wo'; dab tab
expect "completes" 'word11 ' "$(line)"
dab tab
expect "  ... and goes on from the state kept" 'word11 word12 ' "$(line)"

editor 'alpha beta'
typed 'zz'; dab expand
expect "no match: nothing changes" zz "$(line)"
expect "  ... and no Tab is sent" 0 "$(tabs)"

echo "Tab"
editor 'the garden two, three' 'four'
typed 'ga'; dab tab
expect "completes as M-/ does" "garden " "$(line)"
dab tab
expect "again: the word after it on screen" 'garden two ' "$(line)"
dab tab
expect "  ... with what is between, punctuation too" 'garden two, three ' "$(line)"
dab tab
expect "  ... and on to the next line, as a space" 'garden two, three four ' "$(line)"
dab tab
expect "at the end of the screen: nothing more" 'garden two, three four ' "$(line)"
expect "  ... and no Tab is sent" 0 "$(tabs)"

editor 'garden two' 'gamma one'
typed 'ga'; dab expand expand tab
expect "Tab after M-/ goes on from the match M-/ chose" 'gamma one ' "$(line)"

editor 'Your transcription code' 'and Now it' 'Now we'
typed 'Your'; dab tab
expect "Tab on a whole word: the word after it" 'Your transcription ' "$(line)"
dab tab
expect "  ... and on" 'Your transcription code ' "$(line)"
editor 'Your transcription code'
typed 'your'; dab tab
expect "  ... in any case" 'your transcription ' "$(line)"
editor 'and Now it' 'Now we'
typed 'Now'; dab tab
expect "  ... the first of those after it, by the words before" 'Now it ' "$(line)"
dab expand
expect "  ... M-/: the next" 'Now we ' "$(line)"
dab undo undo
expect "  ... undo: back to the word" 'Now' "$(line)"
editor 'Your'
typed 'Your'; dab tab
expect "  ... nothing after it: Tab goes through" '1 Your' "$(tabs) $(line)"

editor 'garden two'
typed 'ga'; dab tab
typed 'x'; dab tab
expect "typing in between starts afresh: x has no match, so Tab goes through" 1 "$(tabs)"
expect "  ... and the line is as typed" 'garden x' "$(line)"

editor 'gamma ga'
typed 'ga'; dab tab
editor 'gamma ga'
typed 'gamma '; dab tab
expect "a state left from before is not gone on from" "1 gamma " "$(tabs) $(line)"

editor 'alpha beta'
typed 'say '; dab tab
expect "nothing before the cursor: Tab goes through" 1 "$(tabs)"
editor 'alpha beta'
typed 'a'; dab tab
expect "one letter: Tab goes through" "1 a" "$(tabs) $(line)"
editor 'alpha beta'
typed 'zz'; dab tab
expect "no match: Tab goes through" "1 zz" "$(tabs) $(line)"
editor 'see src/alpha.py'
typed '@src/al'; dab tab
expect "after @ (the program's own file completion): Tab goes through" "1 @src/al" "$(tabs) $(line)"
editor '/compact /config'
typed '/co'; dab tab
expect "a /command: Tab goes through" "1 /co" "$(tabs) $(line)"

echo "anchors: ^ line starts, . sentence starts, - list items"
# cycle WHAT... — the line after M-/ presses, one per press, joined by |.
cycle() { local got=''; for _ in "$@"; do dab expand; got+="$(line)|"; done; echo "$got"; }
editor 'Howdy partner' 'see Howitzer here' '  Howling at the start'
typed '^How'
expect "^: only words that begin a line, the ^ gone" 'Howdy |Howling |^How|' "$(cycle 1 2 3)"
editor 'Howdy partner' 'see Howitzer here' '  Howling at the start'
tmux set -g @dabbrev-spaced-marks '^'
typed '^ How'
expect "  ... with ^ in @dabbrev-spaced-marks, ^ and a space the same" 'Howdy |Howling |^ How|' "$(cycle 1 2 3)"
tmux set -gu @dabbrev-spaced-marks
editor 'see Howitzer here'
typed '^How'; dab tab
expect "  ... none such: the word completes as any, the ^ kept" '0 ^Howitzer ' "$(tabs) $(line)"
editor 'Thanks first.' '' 'say Thatcher here' 'done. Thawing now: then more.'
typed 'ok. Tha'
expect "\". \" is text, not an anchor: all words" 'ok. Thanks |ok. Thatcher |ok. Thawing |' "$(cycle 1 2 3)"
editor 'say Thatcher here' 'yes! Thanks then.'
typed 'wow! Tha'; dab expand
expect "  ... \"! \" too" 'wow! Thatcher ' "$(line)"
editor 'Some words. The other direction is' '  long here. More'
typed '.th'; dab tab
expect ".word: the sentence that starts so, over a line break" 'The other direction is long here. ' "$(line)"
editor 'The model in four sentences' '' 'more'
typed '.th'; dab tab
expect "  ... with no end, to the block's" 'The model in four sentences ' "$(line)"
editor 'The first item' '- The second' 'x'
typed '.th'; dab tab
expect "  ... or to the next list item" 'The first item ' "$(line)"
editor 'it goes: on and on. done'
typed '.on'; dab tab
expect "  ... a sentence starts after :" 'on and on. ' "$(line)"
editor 'we go: then more. end'
typed 'we ...'; dab tab
expect "... (.. and .) ends at : too" 'we go: ' "$(line)"
editor 'say Whale here' '- Which one' '  * Whatever' '  2. Whence'
typed '- Wh'
expect "\"- \" is text too (a list of your own): all words" '- Whale |- Which |- Whatever |- Whence |' "$(cycle 1 2 3 4)"
editor 'say Whale here' '- Which one' '  * Whatever' '  2. Whence'
typed '-Wh'
expect "-word: list items that start so, whole, the - gone" 'Which one |Whatever |Whence |-Wh|' "$(cycle 1 2 3 4)"
editor 'say Whale here' '- Which one is' '  wrapped on' '  and on' '- Next item' 'after'
typed '-Wh'; dab tab
expect "  ... with the lines it wraps onto" 'Which one is wrapped on and on ' "$(line)"
dab tab
expect "  ... then Tab goes on after it" 'Which one is wrapped on and on Next ' "$(line)"
editor '- Which one' '' 'not of it'
typed '-W'; dab tab
expect "  ... a blank line ends it" 'Which one ' "$(line)"
editor '1. First thing' '2. Second thing' '   wrapped' '3. Third' 'and 2. Other' '  2) Again here'
typed '2.'
expect "N. : the items numbered so, whole" '2. Second thing wrapped |2. Again here |2.|' "$(cycle 1 2 3)"
editor 'version 2.5 here'
typed '2.'; dab tab
expect "  ... no such item: as before" '2.5 ' "$(line)"

LIST=('Thanks first.' 'Howdy partner' 'say Whale here' '- Which one' 'gcc -Wall now')
tmux set -g @dabbrev-spaced-marks '^'
for t in '^H|Howdy ' '^ H|Howdy ' '-W|Which one ' '.t|Thanks first. '; do
    editor "${LIST[@]}"
    typed "${t%%|*}"; dab tab
    expect "Tab on one letter after an anchor: ${t%%|*}" "0 ${t#*|}" "$(tabs) $(line)"
done
tmux set -gu @dabbrev-spaced-marks
for t in '- W' '. T'; do
    editor "${LIST[@]}"
    typed "$t"; dab tab
    expect "  ... not after text: one letter, Tab goes through: $t" "1 $t" "$(tabs) $(line)"
done
editor "${LIST[@]}"
typed '-Wal'; dab tab
expect "  ... -W with no such list item: as before, the - kept" '-Wall ' "$(line)"
editor 'Thanks first.' 'say Thatcher here' 'done. Thawing now.' 'see .thatrc'
typed '.th'
expect ".word: the sentences that start so, whole, the . gone" 'Thanks first. |Thawing now. |.th|' "$(cycle 1 2 3)"
editor 'say Thatcher here' 'see .thatrc'
typed 'x .thatr'; dab tab
expect "  ... with none such: as before, the . kept" 'x .thatrc ' "$(line)"
editor "${LIST[@]}"
typed 'W'; dab tab
expect "  ... one letter alone still goes through" '1 W' "$(tabs) $(line)"

editor $'  \e[1mDoes \e[38;5;105mWhen\e[39m set up a listener?\e[0m Not quite. A \e[38;5;105mWhen\e[39m is'
typed '=D'; dab tab
expect "=: a stretch in styles not the default is one, longer first at a place" 'Does When set up a listener? ' "$(line)"
editor $'  \e[1mDoes \e[38;5;105mWhen\e[39m set up a listener?\e[0m Not quite. A \e[38;5;105mWhen\e[39m is'
typed '=Wh'; dab tab
expect "  ... the runs in it too" 'When ' "$(line)"
QUOTED=('Thanks first.' 'Howdy partner' '- Which one' '' $'  \e[1mThe model\e[0m here' '' 'x')
for t in 're: "=T|re: "The model" ' 're: "^H|re: "Howdy" ' 're: "-W|re: "Which one" ' "('.th|('The model here' " 're: "^T..$$|re: "The model here" '; do
    editor "${QUOTED[@]}"
    typed "${t%%|*}"; dab tab
    expect "after a quote or a bracket too: ${t%%|*}" "${t#*|}" "$(line)"
done
ENT=($'a \e[36mWhen\e[39m arrives' 'plain Whale and When' $'\e[34mWhen /someone/ wishes /p/\e[39m is it')
editor "${ENT[@]}"
typed '=wh'
expect "=word: only entities, those of more words first, the = gone" 'When /someone/ wishes /p/ |When |=wh|' "$(cycle 1 2 3)"
editor "${ENT[@]}"
typed '=w'; dab tab tab
expect "  ... one letter is enough; Tab goes on after it" 'When /someone/ wishes /p/ is ' "$(line)"
editor "${ENT[@]}"
typed '=zz'; dab tab
expect "  ... none such: nothing, Tab goes through" '1 =zz' "$(tabs) $(line)"

echo "...word: up to the word (inclusive: @dabbrev-ruby-ranges off)"
tmux set -g @dabbrev-ruby-ranges off
PARA=('we keep them in ppi for now, while' '  you are changing them. Move them out once' '  they settle, so ppi consumes. Then more')
editor "${PARA[@]}"
typed 'keep'; dab tab tab
typed '...consumes'; dab tab
expect "after Tabs: from there to the word, with what is on it" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. ' "$(line)"
dab tab
expect "  ... then Tab goes on word by word" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. Then ' "$(line)"
dab undo undo
expect "  ... undo: back to what was typed" 'keep them in ...consumes' "$(line)"
editor "${PARA[@]}"
typed 'keep them in ...cons'; dab tab
expect "without Tabs before: from where the words before it are" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. ' "$(line)"
editor "${PARA[@]}"
typed 'keep them in ...Move'; dab tab
expect "  ... to the first such word" 'keep them in ppi for now, while you are changing them. Move ' "$(line)"
editor "${PARA[@]}"
typed 'keep them in ...th'; dab tab
expect "  ... by prefix, smart case" 'keep them in ppi for now, while you are changing them. ' "$(line)"
dab expand
expect "  ... M-/: on to the next such word" 'keep them in ppi for now, while you are changing them. Move them ' "$(line)"
dab expand
expect "  ... and the next" 'keep them in ppi for now, while you are changing them. Move them out once they ' "$(line)"
editor "${PARA[@]}"
typed 'keep them in ...zzz'; dab tab
expect "no such word after: Tab goes through" '1 keep them in ...zzz' "$(tabs) $(line)"
editor '4. Where Folk came from. Folk is a' '   physical system. Programs run' 'x'
typed '4. ...P'; dab tab
expect "  ... what was typed after the last word is not taken twice (4. )" \
    '4. Where Folk came from. Folk is a physical system. Programs ' "$(line)"
editor "${PARA[@]}"
typed 'keep them ...$'
dab tab
expect "...\$: to the end of the line" 'keep them in ppi for now, while ' "$(line)"
editor "${PARA[@]}" '' 'next paragraph'
typed 'keep them ...$$'; dab tab
expect "...\$\$: to the end of the block (a blank line)" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. Then more ' "$(line)"
editor '- one item here' '  wraps on' '- two' 'x' '' 'after'
typed 'one ...$$'; dab tab
expect "  ... lists in it too: up to a blank row" 'one item here wraps on - two x ' "$(line)"
for op in '..cons' '... cons' '.. cons'; do
    editor "${PARA[@]}"
    typed "keep them in $op"; dab tab
    expect "${op}: as ...cons (.. or ..., a space or none)" \
        'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. ' "$(line)"
done
for op in '....' '...' '.. .'; do
    editor "${PARA[@]}"
    typed "keep them $op"
    expect "${op}: to the end of the sentence, M-/ the next" \
        'keep them in ppi for now, while you are changing them. |keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. |' "$(cycle 1 2)"
done
editor 'we ask is it so? yes! see file.py now. done' 'x'
typed 'ask ...?'; dab tab
expect "...?: to the next ?" 'ask is it so? ' "$(line)"
editor 'we ask is it so? yes! see file.py now. done' 'x'
typed 'ask ..!'; dab tab
expect "..!: to the next !" 'ask is it so? yes! ' "$(line)"
editor 'we ask is it so? yes! see file.py now. done' 'x'
typed 'see ...'; dab tab
expect "  ... a . inside a word ends no sentence" 'see file.py now. ' "$(line)"
BLOCK=('The other direction: a pattern without claims, such' '  as When /p/ is, matches claims. That is in' '  prelude.tcl: if not, it queries' '' 'Then later')
WHOLE='The other direction: a pattern without claims, such as When /p/ is, matches claims. That is in prelude.tcl: if not, it queries '
tmux set -g @dabbrev-spaced-marks '^'
for q in '^T..$$' '^T ..$$' '^ T ...$$'; do
    editor "${BLOCK[@]}"
    typed "$q"; dab tab
    expect "${q}: an anchored query before .. is completed first" "$WHOLE" "$(line)"
done
tmux set -gu @dabbrev-spaced-marks
editor "${BLOCK[@]}"
typed '^T..$$'; dab tab expand
expect "  ... M-/: the next block that starts so" 'Then later ' "$(line)"
dab expand
expect "  ... past the last: what was typed" '^T..$$' "$(line)"
ITEM=('- First sentence here. And then' '  more of the item.' '- Second one' 'x')
for q in '-F...' '-F....' '-F ...' '-F..here'; do
    editor "${ITEM[@]}"
    typed "$q"; dab tab
    expect "${q}: in a query a mark stands for its word, not the whole item" 'First sentence here. ' "$(line)"
done
editor "${ITEM[@]}"
typed '-F..$'; dab tab
expect "  ... -F..\$: the item's first row" 'First sentence here. And then ' "$(line)"
TWICE=('The model in four' '' 'The other direction: a' '  pattern here.' '' 'x')
editor "${TWICE[@]}"
typed '^T..$$'; dab tab
expect "  ... each place, not each word: the first The" 'The model in four ' "$(line)"
dab expand
expect "  ... M-/: the other The, its block of two rows" 'The other direction: a pattern here. ' "$(line)"
editor "${TWICE[@]}"
typed '^The other..$$'; dab tab
expect "  ... a query of words: the first anchored, the rest after it" 'The other direction: a pattern here. ' "$(line)"
editor "${TWICE[@]}"
typed '^The oth ..$'; dab tab
expect "  ... each word of it a prefix" 'The other direction: a ' "$(line)"
editor "${PARA[@]}"
typed 'keep them in..cons'; dab tab
expect "..word right after a word, no space" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. ' "$(line)"
BLOCK2=('The pattern has claims in it' 'x' 'That one claims too' '' 'Then later')
editor "${BLOCK2[@]}"
typed '^T ..cl'; dab tab
expect "  ... with any end: the first in each" 'The pattern has claims ' "$(line)"
dab expand
expect "  ... M-/: the next that starts so, not the next end" 'That one claims ' "$(line)"
editor "${PARA[@]}"
typed '...cons'; dab tab
expect "nothing before it: the word completes as any" '0 ...consumes ' "$(tabs) $(line)"

tmux set -gu @dabbrev-ruby-ranges

echo "Ruby's ranges (@dabbrev-ruby-ranges, on by default): ... leaves the end out, .. takes it"
editor "${PARA[@]}"
typed 'keep them in ...consumes'; dab tab
expect "...word: up to the word, not it" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi ' "$(line)"
dab tab
expect "  ... Tab goes on with it" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes ' "$(line)"
editor "${PARA[@]}"
typed 'keep them in ..consumes'; dab tab
expect "..word: up to and with it" \
    'keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes. ' "$(line)"
editor "${PARA[@]}"
typed 'keep them ....'
expect "....: the sentence without its end" \
    'keep them in ppi for now, while you are changing them |keep them in ppi for now, while you are changing them. Move them out once they settle, so ppi consumes |' "$(cycle 1 2)"
editor "${PARA[@]}"
typed 'keep them ...'; dab tab
expect "...: (.. and .) the sentence with it" 'keep them in ppi for now, while you are changing them. ' "$(line)"
editor 'we ask is it so? yes! see' 'x'
typed 'ask ...?'; dab tab
expect "...?: up to the ?, not it" 'ask is it so ' "$(line)"
editor "${PARA[@]}"
typed 'keep them ...$'; dab tab
expect "...\$: as ..\$ (nothing to leave out)" 'keep them in ppi for now, while ' "$(line)"
editor '- First sentence here. And then' '  more of the item.' '- Second one' 'x'
typed '-F....'; dab tab
expect "  ... after a query too" 'First sentence here ' "$(line)"

echo "_word: the row that starts so (^word..\$)"
LINES=('xyz is the line here' 'see xyzzy too' '  xyz again' 'a _private_name here')
editor "${LINES[@]}"
typed '_xy'
expect "_xy: each row that starts so, whole; M-/ the next" 'xyz is the line here |xyz again |_xy|' "$(cycle 1 2 3)"
editor "${LINES[@]}"
typed '_pri'; dab tab
expect "  ... no such row: as before (an identifier)" '_private_name ' "$(line)"
editor "${LINES[@]}"
typed 'say "_xy'; dab tab
expect "  ... closed after a quote" 'say "xyz is the line here" ' "$(line)"
printf 'rr  re: "|" --\\s\n' > "$SCRATCH/rr.snippets"
tmux set -g @dabbrev-snippets "$SCRATCH/rr.snippets"
editor "${LINES[@]}"
typed ',r'; dab tab
typed '_xy'; dab tab
expect "  ... ,r then _xy: inside the snippet's quotes" 're: "xyz is the line here" -- ' "$(line)"
tmux set -gu @dabbrev-snippets

echo "chains: several operators in one press"
CHAIN=('1. First thing' '2. Second thing' '- Which one' '- Whatever else' '' $'\e[1mDoes When\e[0m set up?')
editor "${CHAIN[@]}"
typed '1., 2.'; dab tab
expect "1., 2.: both items, joined as typed" '1. First thing, 2. Second thing ' "$(line)"
dab undo
expect "  ... undo: back to what was typed" '1., 2.' "$(line)"
editor "${CHAIN[@]}"
typed 'see 1., -Wh'; dab tab expand
expect "  ... M-/ cycles the last" 'see 1. First thing, Whatever else ' "$(line)"
printf 'rr  re: "|" --\\s\n' > "$SCRATCH/rr.snippets"
tmux set -g @dabbrev-snippets "$SCRATCH/rr.snippets"
editor "${CHAIN[@]}"
typed ',r=Does'; dab tab
expect ",r=Does: the snippet, the entity in its quotes, the cursor after it" 're: "Does When" -- |14' "$(line)|$(cursor)"
dab tab
expect "  ... Tab goes on there" 're: "Does When set" -- |18' "$(line)|$(cursor)"
dab undo undo
expect "  ... undo back to what was typed" ',r=Does|7' "$(line)|$(cursor)"
tmux set -gu @dabbrev-snippets
printf 'rr  re: "|" --\\s\n' > "$SCRATCH/rr.snippets"
tmux set -g @dabbrev-snippets "$SCRATCH/rr.snippets"
editor 'Snapshot of the state' 'The model' 'Then more'
typed 'see Snapshot | ,r'; dab tab
expect "| : the word before it into the snippet, the cursor after it all" 'see re: "Snapshot" -- |22' "$(line)|$(cursor)"
dab undo
expect "  ... undo: back to what was typed" 'see Snapshot | ,r|17' "$(line)|$(cursor)"
editor 'Snapshot of the state' 'The model' 'Then more'
typed '^Th | ,r'; dab tab expand
expect "  ... ^Th | ,r, M-/: the next match in it" 're: "Then" -- ' "$(line)"
tmux set -gu @dabbrev-snippets
editor 'Snapshot of the state'
typed 'see hello |('; dab tab
expect "LEFT |( : LEFT in the pair, the cursor after it" 'see (hello)|11' "$(line)|$(cursor)"
dab undo
expect "  ... undo: back to what was typed" 'see hello |(|12' "$(line)|$(cursor)"
editor 'Snapshot of the state'
typed 'see hello |()'; tmux send-keys -t "$PANE" Left; sleep 0.2; dab tab
expect "  ... the closer after the cursor already: against it, the cursor before it" 'see (hello)|10' "$(line)|$(cursor)"
editor 'hello world here'
typed '_h'; dab tab; typed '|('; dab tab
expect "  ... right after a completion: the word before the |" 'hello world (here)|18' "$(line)|$(cursor)"
tmux set -g @dabbrev-pipe-completion on
editor 'hello world here'
typed '_h'; dab tab; typed '|('; dab tab
expect "  ... @dabbrev-pipe-completion on: the whole completion" '(hello world here)|18' "$(line)|$(cursor)"
dab undo
expect "  ... undo: back to what was typed" 'hello world here |(' "$(line)"
tmux set -gu @dabbrev-pipe-completion
editor "${CHAIN[@]}"
typed '"1., 2.'; dab tab
expect "  ... after a quote: the chain closed" '"1. First thing, 2. Second thing" ' "$(line)"

echo "after an opening quote or bracket, the completion is closed"
editor 'say hello world here'
typed 'x "hel'; dab tab
expect "the closer after it" 'x "hello" ' "$(line)"
closed() { tmux show-options -pqv -t "$PANE" @dabbrev-closed; }
editor 'say hello world here'
typed 'x <hel'; dab tab
expect "  ... < is not one of the pairs by default: not closed" 'x <hello ' "$(line)"
editor 'say hello world here'
typed 'x “hel'; dab tab
expect "  ... nor “" 'x “hello ' "$(line)"
tmux set -g @tmux-tools-pairs '()<>'
editor 'say hello world here'
typed 'x <hel'; dab tab
expect "  ... closed when @tmux-tools-pairs has it" 'x <hello> ' "$(line)"
tmux set -gu @tmux-tools-pairs
editor 'say hello world here'
typed 'x "hel'; dab tab
expect "  ... where it ends and the closer, in @dabbrev-closed (for electric-pair)" "12 $ROW \"" "$(closed)"
dab tab
expect "  ... and on after the words Tab adds" 'x "hello world" ' "$(line)"
expect "  ... @dabbrev-closed with it" "18 $ROW \"" "$(closed)"
dab undo
expect "  ... undo with it" 'x "hello" ' "$(line)"
dab undo
expect "  ... back to what was typed" 'x "hel' "$(line)"
expect "  ... @dabbrev-closed gone" '' "$(closed)"
editor 'say hello world here'
typed '"hello'; dab tab
expect "  ... a whole word: on to the next, closed" '"hello world" ' "$(line)"
for t in '(hel|(hello) ' '[hel|[hello] ' "'hel|'hello' " '`hel|`hello` '; do
    editor 'say hello world here'
    typed "${t%%|*}"; dab tab
    expect "  ... ${t%%|*}" "${t#*|}" "$(line)"
done
editor $'and \e[1mClaude Code\e[0m too'
typed '"=Cl'; dab tab
expect "  ... after an anchor too" '"Claude Code" ' "$(line)"
editor 'say hello world here'
typed 'f(hel'; dab tab
expect "  ... not after one that does not begin a word" 'f(hello ' "$(line)"
printf 'rr  re: "|" --\\s\n' > "$SCRATCH/rr.snippets"
tmux set -g @dabbrev-snippets "$SCRATCH/rr.snippets"
editor $'see \e[1mThe model\e[0m here'
typed ',rr'; dab tab
typed '=T'; dab tab
expect "  ... not when the closer is right after the cursor (,rr then =T): up to it" 're: "The model" -- |14' "$(line)|$(cursor)"
dab tab
expect "  ... and Tab goes on there" 're: "The model here" -- |19' "$(line)|$(cursor)"
tmux set -gu @dabbrev-snippets
editor 'say "hello world" here'
typed '"hel'; dab tab tab tab
expect "  ... not once what it takes holds the closer" '"hello world" here ' "$(line)"

echo "M-/ after Tab: the other words that follow"
editor 'alpha gamma two' 'alpha beta one'
typed 'al'; dab tab tab
expect "Tab: the word after the highest alpha" 'alpha gamma ' "$(line)"
dab expand
expect "M-/: the word after another alpha" 'alpha beta ' "$(line)"
dab expand
expect "  ... past the last: back to before the Tab" 'alpha ' "$(line)"
dab expand
expect "  ... and round again" 'alpha gamma ' "$(line)"
dab expand tab
expect "Tab goes on from the alpha M-/ chose" 'alpha beta one ' "$(line)"
dab undo
expect "undo takes back that Tab" 'alpha beta ' "$(line)"
dab undo
expect "  ... then the M-/ presses, one at a time" 'alpha gamma ' "$(line)"
dab undo
expect "  ... " 'alpha ' "$(line)"

editor 'see alpha beta' 'alpha beta' 'alpha delta'
typed 'see al'; dab tab tab expand
expect "the same word after two alphas is one choice" 'see alpha delta ' "$(line)"

echo "paths"
F="$SCRATCH/files"
mkdir -p "$F/alps/other" "$F/far/away"
touch "$F/alpha.txt" "$F/Beta.md" "$F/.hidden" "$F/alps/inner.txt"
CWD="$F"
editor 'alpha.txt alpine'
typed './al'; dab expand
expect "./ completes from the files, not the screen; a file and a space" './alpha.txt ' "$(line)"
dab expand
expect "  ... again: the next, a folder and a /" './alps/' "$(line)"
dab expand
expect "  ... past the last: back to what was typed" './al' "$(line)"
editor
typed './alps'; dab tab
expect "Tab completes the folder" './alps/' "$(line)"
dab tab
expect "  ... again: what is in it" './alps/inner.txt ' "$(line)"
dab expand
expect "  ... M-/: the next thing in it" './alps/other/' "$(line)"
dab expand
expect "  ... past the last: back to the folder" './alps/' "$(line)"
dab undo undo
expect "  ... undo goes back press by press" './alps/inner.txt ' "$(line)"
editor
typed './alps'; dab tab
typed 'ot'; dab tab
expect "typing after a folder: completes in it" './alps/other/' "$(line)"
editor
typed './alps/inner.txt'; dab tab tab
expect "after a file, Tab adds nothing" '0 ./alps/inner.txt ' "$(tabs) $(line)"
editor
typed './b'; dab expand
expect "smart case" './Beta.md ' "$(line)"
editor
typed './'; dab expand
expect "dotfiles stay out" './alpha.txt ' "$(line)"
editor
typed './.h'; dab expand
expect "  ... unless what was typed starts with a dot" './.hidden ' "$(line)"
editor
typed 'see ~/Be'; dab tab
expect "~/ from the home folder" 'see ~/Beta.md ' "$(line)"
editor
typed "see //${F#/}/fa"; dab tab tab
expect "// stands for / (alone, / is the program's commands)" "see $F/far/away/" "$(line)"
editor
typed "$F/Be"; dab tab
expect "so does a word starting /folder/" "$F/Beta.md " "$(line)"
editor
typed "//${F#/}/Be"; dab tab undo
expect "  ... and undo gives back the //" "//${F#/}/Be" "$(line)"
CWD="$F/alps"
editor
typed '(../Be'; dab tab
expect "../, after a bracket (and closed)" '(../Beta.md) ' "$(line)"
editor
typed './zz'; dab tab
expect "no such file: Tab goes through" '1 ./zz' "$(tabs) $(line)"
editor 'https://alpha.example'
typed 'https://al'; dab tab
expect "a URL is no path: completes from the screen" 'https://alpha.example ' "$(line)"
CWD="$F"
editor "see ~/alps/inner.txt and $F/ghost/file.txt"
typed '~/al'; dab expand
expect "paths on screen come before the files" '~/alps/inner.txt ' "$(line)"
dab expand
expect "  ... then the files" '~/alpha.txt ' "$(line)"
editor "see $F/ghost/file.txt"
typed '~/gh'; dab expand
expect "  ... a path on screen under the home folder, as ~/" '~/ghost/file.txt ' "$(line)"
editor 'see ./alps, ./ghost.txt.'
typed './a'; dab expand
expect "  ... a folder on screen ends in /" './alps/' "$(line)"
editor 'see ./alps, ./ghost.txt.'
typed './g'; dab expand
expect "  ... punctuation after it is not part of it" './ghost.txt ' "$(line)"
editor $'see \e[36m./with space.txt\e[0m here'
typed './w'; dab expand
expect "  ... a coloured path takes its spaces" './with space.txt ' "$(line)"
CWD="$SCRATCH"

echo "coloured spans"
editor $'see \e[33mabc-123:45\e[0m now'
typed 'ab'; dab expand
expect "a coloured span is a completion, before the word in it" 'abc-123:45 ' "$(line)"
dab expand
expect "  ... then the word" 'abc-123 ' "$(line)"
editor $'\e[38;5;105mTranscribe/_jobs/<batch>.cell.py\e[39m is far' 'Transcribe/notes nearer' 'Transcribed here'
typed 'Tr'; dab tab
expect "  ... even a far one comes before the nearer words" 'Transcribe/_jobs/<batch>.cell.py ' "$(line)"
dab expand
expect "  ... then the words, from the top" 'Transcribe/_jobs ' "$(line)"
editor $'fixed in \e[1m<v4521>\e[0m today'
typed '<v'; dab expand
expect "  ... it may start with what is not a letter" '<v4521> ' "$(line)"
editor $'x \e[36mfoo bar\e[0m y'
typed 'fo'; dab expand
expect "  ... with spaces too" 'foo bar ' "$(line)"
editor 'trans1 trans1 trans1' $'see \e[36mtrans2\e[0m'
typed 'tr'; dab expand
expect "  ... a coloured word is a span, before the more frequent plain one" 'trans2 ' "$(line)"
editor $'see \e[36m["a1f3", "b72c"]\e[0m: the ids'
typed '['; dab expand
expect "  ... what was typed may be punctuation only" '["a1f3", "b72c"] ' "$(line)"
editor $'see \e[36m["a1f3", "b72c"]\e[0m: the ids'
typed '["'; dab tab
expect "  ... with Tab, two of it" '0 ["a1f3", "b72c"] ' "$(tabs) $(line)"
editor $'see \e[36m["a1f3", "b72c"]\e[0m: the ids'
typed 'x ['; dab tab
expect "  ... one is not enough for Tab" '1 x [' "$(tabs) $(line)"
editor 'see (alpha)'
typed '('; dab expand
expect "  ... and completes no plain word" '(' "$(line)"
editor $'see \e[1mswiz:\e[0m and swizzle'
typed 'sw'; dab expand
expect "  ... punctuation at its end is not part of it" 'swiz ' "$(line)"
editor $'\e[2mgrey all over\e[0m'
typed 'gr'; dab expand expand
expect "a whole faint line is no span" 'gr' "$(line)"
editor $'\e[48;5;189mbg all over\e[0m'
typed 'bg'; dab expand expand
expect "  ... nor one with a background (a diff's)" 'bg' "$(line)"
editor 'the more' '' $'  \e[1m\e[48;5;189mThe model in four sentences\e[0m' '' 'x'
typed '=T'; dab tab
expect "  ... but a whole bold line is, background or not (a heading)" 'The model in four sentences ' "$(line)"
editor $'\e[31mred\e[0m'
typed 'r'; dab expand
expect "  ... nor is the word it is" 'red ' "$(line)"

echo "entities: coloured spans, CamelCase, Capitalised Words"
editor 'parsed one' 'x ParserState'
typed 'pa'; dab expand
expect "a CamelCase word ranks as a coloured span" 'ParserState ' "$(line)"
editor 'getter one' 'x getValue'
typed 'ge'; dab expand
expect "  ... so does camelCase" 'getValue ' "$(line)"
editor 'claude is' 'see Claude Code here'
typed 'cl'; dab expand
expect "two or more Capitalised Words are one" 'Claude Code ' "$(line)"
editor 'claude is' 'see Claude Code Opus here'
typed 'cl'; dab expand
expect "  ... as many as there are" 'Claude Code Opus ' "$(line)"
editor 'clear' 'Claude alone'
typed 'cl'; dab expand
expect "  ... one alone is a word" 'clear ' "$(line)"
editor 'whence' 'When I go'
typed 'wh'; dab expand
expect "  ... a word of one letter is not in a run" 'whence ' "$(line)"
editor 'htmlx' 'the HTML here'
typed 'ht'; dab expand
expect "capitals alone are no CamelCase" 'htmlx ' "$(line)"
tmux set -g @dabbrev-entities 'coloured capitalised'
editor 'parsed one' 'x ParserState and Claude Code'
typed 'pa'; dab expand
expect "@dabbrev-entities: the kinds wanted (no camelcase here)" 'parsed ' "$(line)"
editor 'claude is' 'see Claude Code here'
typed 'cl'; dab expand
expect "  ... and the others still" 'Claude Code ' "$(line)"
tmux set -g @dabbrev-entities ''
editor $'abcd one' $'see \e[36mabc-123:45\e[0m'
typed 'ab'; dab expand
expect "  ... none: not even coloured spans" 'abcd ' "$(line)"
tmux set -gu @dabbrev-entities

echo "orders (@dabbrev-order)"
ORDERED=(gamma x x x garden x gallop x gazebo x)     # rows 0-9; the cursor's is 10 of 12
order() {
    if [ "$1" = default ]; then tmux set -gu @dabbrev-order; else tmux set -g @dabbrev-order "$1"; fi
    editor "${ORDERED[@]}"
    typed 'ga'; local got=''
    for _ in 1 2 3 4; do dab expand; got+="$(line | tr -d ' ') "; done
    echo "$got"
}
expect "middle (the default): nearest the middle of the screen" 'gallop garden gazebo gamma ' "$(order default)"
expect "cursor: nearest the cursor" 'gazebo gallop garden gamma ' "$(order cursor)"
expect "top: from the top" 'gamma garden gallop gazebo ' "$(order top)"
expect "an unknown order is the default" 'gallop garden gazebo gamma ' "$(order nonesuch)"
ORDERED=(gamma x x 'gazebo gazebo' garden x gallop x)
expect "frequent: the most often on screen first" 'gazebo gallop garden gamma ' "$(order frequent)"
expect "  ... which the default is not" 'gallop garden gazebo gamma ' "$(order default)"
tmux set -gu @dabbrev-order
editor $'before, \e[36mtranscribe\e[39m and a transcript' $'\e[38;5;105mTranscribe/_jobs/<b>.cell.py\e[39m here' \
    $'few lines \e[36mtranscribe\e[39m fills' $'so any transcript, and \e[1mtranscribe status <b>\e[0m tells'
typed 'trans'; got=''
for _ in 1 2 3 4; do dab expand; got+="$(line)|"; done
expect "  ... the coloured ones first, by @dabbrev-span-order (default middle)" \
    'transcribe status <b> |transcribe |Transcribe/_jobs/<b>.cell.py |transcript |' "$got"
tmux set -g @dabbrev-span-order frequent
editor $'before, \e[36mtranscribe\e[39m and a transcript' $'\e[38;5;105mTranscribe/_jobs/<b>.cell.py\e[39m here' \
    $'few lines \e[36mtranscribe\e[39m fills' $'so any transcript, and \e[1mtranscribe status <b>\e[0m tells'
typed 'trans'; got=''
for _ in 1 2 3 4; do dab expand; got+="$(line)|"; done
expect "  ... which may be another" \
    'transcribe |transcribe status <b> |Transcribe/_jobs/<b>.cell.py |transcript |' "$got"
tmux set -gu @dabbrev-span-order
tmux set -g @dabbrev-order middle
editor x x x x x gamma garden                         # rows 5 and 6: as far from the middle, 5.5
typed 'ga'; dab expand
expect "middle: of two as far from it, the lower" 'garden ' "$(line)"
tmux set -g @dabbrev-order top

echo "snippets (,name)"
SNIP="$SCRATCH/snippets"
cat > "$SNIP" <<'EOF'
# NAME  TEXT
rr      re: "|" --\s
rs      rest
sig     Best,\nB
bar     a \| b
EOF
tmux set -g @dabbrev-snippets "$SNIP"
editor 'nothing'
typed ',rr'; dab tab
expect "Tab expands, the cursor where | was" 're: "" -- |5' "$(line)|$(cursor)"
dab undo
expect "  ... undo takes it back" ',rr|3' "$(line)|$(cursor)"
editor 'nothing'
typed 'see ,r'; dab expand
expect "M-/: the first whose name starts so" 'see re: "" -- ' "$(line)"
dab expand
expect "  ... again: the next, from where the cursor was" 'see rest|8' "$(line)|$(cursor)"
dab expand
expect "  ... past the last: what was typed" 'see ,r|6' "$(line)|$(cursor)"
editor 'nothing'
typed ','; dab expand
expect "a comma alone: all of them, by name" 'a | b' "$(line)"
editor 'nothing'
typed ',sig'; dab tab
expect "a line break is pasted, not typed" "$(printf 'Best,\nB')" "$(line)"
dab undo
expect "  ... and taken back" ',sig' "$(line)"
editor 'nothing'
typed ',bar'; dab tab
expect "a backslash and a bar: a bar" 'a | b' "$(line)"
editor 'rrr'
typed ',zz'; dab tab
expect "no such snippet: Tab goes through" '1 ,zz' "$(tabs) $(line)"
editor 'nothing'
typed 'a,rr'; dab tab
expect "a comma inside a word is no snippet" '1 a,rr' "$(tabs) $(line)"
tmux set -g @dabbrev-snippets "$SCRATCH/none"
editor 'nothing'
typed ',rr'; dab tab
expect "no snippets file: Tab goes through" '1 ,rr' "$(tabs) $(line)"
tmux set -g @dabbrev-snippets "$SNIP"

echo "M-? (undo)"
editor 'garden two three'
typed 'ga'; dab tab tab
dab undo
expect "takes back the last Tab" 'garden ' "$(line)"
dab undo
expect "  ... and the first, back to what was typed" ga "$(line)"
dab undo
expect "  ... and no further" ga "$(line)"
dab tab
expect "  ... where Tab completes again" 'garden ' "$(line)"

editor 'garden two' 'gamma one'
typed 'ga'; dab expand expand undo
expect "takes back an M-/: the match before" 'garden ' "$(line)"
dab expand
expect "  ... and M-/ goes on from there" 'gamma ' "$(line)"

editor 'gamma'
typed 'ga'; dab undo
expect "with nothing to take back: nothing, and no key sent" "0 ga" "$(tabs) $(line)"

echo "bind"
tmux set -g @dabbrev-tab-commands 'python3 claude'
python3 "$DAB" bind
expect "M-/ runs it, in the foreground (keys typed after it wait)" 1 \
    "$(tmux list-keys -T root | grep -cE "root +M-/ +run-shell \"[^ ]*tmux-dabbrev expand '#\{pane_id\}'\"")"
expect "M-? undoes" 1 \
    "$(tmux list-keys -T root | grep -cE "root +M-\\? +run-shell \"[^ ]*tmux-dabbrev undo '#\{pane_id\}'\"")"
expect "Tab runs it in the configured programs, else is sent on" 1 \
    "$(tmux list-keys -T root | grep -F 'Tab' | grep -F 'python3|claude' | grep -F 'tmux-dabbrev tab' | grep -c 'send-keys Tab')"
tmux set -g @dabbrev-key M-.
tmux set -g @dabbrev-undo-key M-,
tmux set -g @dabbrev-tab-commands ''
python3 "$DAB" bind
expect "other keys, the old ones unbound, and no Tab" "1 1 0 0 0" \
    "$(tmux list-keys -T root | grep -cE 'root +M-\. ') $(tmux list-keys -T root | grep -cE 'root +M-, ') $(tmux list-keys -T root | grep -cE 'root +M-/ ') $(tmux list-keys -T root | grep -cE 'root +M-\? ') $(tmux list-keys -T root | grep -cE 'root +Tab ')"
tmux set -gu @dabbrev-undo-key

echo "keys pressed in a client"
# The bindings as a terminal reaches them: a client of the server, run in a
# pane of another, gets M-/ and Tab.
editor 'garden two' 'gamma one'
tmux set -gu @dabbrev-key
tmux set -g @dabbrev-tab-commands "$(tmux display -p -t "$PANE" '#{pane_current_command}')"  # the editor
python3 "$DAB" bind
mkdir -p "$SCRATCH/o"
TMUX_TMPDIR="$SCRATCH/o" tmux -f /dev/null new-session -d -x 80 -y 13 \
    "env -u TMUX TMUX_TMPDIR=$SCRATCH tmux attach"
sleep 0.8
outer() { TMUX_TMPDIR="$SCRATCH/o" tmux send-keys "$@"; sleep 0.4; }
editor 'garden two' 'gamma one'
outer -l ga; outer M-/; outer M-/
expect "M-/ twice" "gamma " "$(line)"
outer Tab
expect "  ... then Tab" 'gamma one ' "$(line)"
outer M-?
expect "  ... then M-? takes the Tab back" 'gamma ' "$(line)"
outer -l 'zz'; outer Tab
expect "Tab with nothing to complete reaches the program" "1 gamma zz" "$(tabs) $(line)"
tmux set -g @dabbrev-tab-commands 'claude'
python3 "$DAB" bind
outer Tab
expect "in other programs Tab goes straight through" 2 "$(tabs)"
tmux set -g @dabbrev-tab-commands 'claude py.*'
python3 "$DAB" bind
editor 'garden two'
outer -l ga; outer Tab
expect "the programs are regular expressions for the whole name" 'garden ' "$(line)"
tmux set -gu @dabbrev-tab-commands
python3 "$DAB" bind
expect "  ... by default with [0-9.]+ (Claude Code on macOS is named for its version)" 1 \
    "$(tmux list-keys -T root Tab | grep -cF '|[0-9.]+)')"
TMUX_TMPDIR="$SCRATCH/o" tmux kill-server

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
