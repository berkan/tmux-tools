#!/usr/bin/env bash
# Tests for config/tmux-dabbrev's language and matching, without tmux: the
# script's code runs on a stand-in pane (the screen's rows and the text left
# of the cursor given here), so each case takes no time. What only a real
# pane shows (typing, the cursor, paste, the keys) is tests/dabbrev.test.sh.
# Needs python3.
#
#   bash tests/dabbrev-logic.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/dabbrev-logic.XXXXXX")" && pwd)"
trap 'rm -rf "$SCRATCH"' EXIT

python3 - "$HERE/../bin/tmux-dabbrev" "$SCRATCH" <<'EOF'
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader('dabbrev', sys.argv[1])
d = importlib.util.module_from_spec(importlib.util.spec_from_loader('dabbrev', loader))
loader.exec_module(d)
scratch = sys.argv[2]
OPTIONS = {}                                    # the tmux options the script reads
d.tmux = lambda *args, check=True: OPTIONS.get(args[-1], '') if args[:2] == ('show-options', '-gqv') else ''


class Pane(d.Pane):
    """ROWS on screen, the cursor's row below them with BEFORE left of it."""
    def __init__(self, rows, before, after=''):
        self.pane, self.pid = '%0', 1
        self.screen, self.cy = list(rows) + ['> ' + before + after], len(rows)
        self.before, self.after = '> ' + before, after
        self.middle = len(self.screen) / 2
        self._cwd, self._escaped = '/', list(self.screen)
        self._order = {False: 'top', True: 'top'}
        self._kinds = {'camelcase', 'capitalised'}
        self._sugars = None

    def state(self, before=None):
        return None


def alternatives(rows, before, key='tab'):
    pane = Pane(rows, before)
    for backend in d.BACKENDS:
        found = backend.typed(pane, key)
        if found:
            break
    else:
        return None
    alts = backend.complete(pane, *found)
    return [alt['text'] for alt in alts] if backend.name != 'program' else 'program'


passed = failed = 0
def expect(name, want, rows, before, key='tab'):
    global passed, failed
    got = alternatives(rows, before, key)
    got = got[:len(want)] if isinstance(want, list) and isinstance(got, list) else got
    if got == want:
        passed += 1; print('  ✓', name)
    else:
        failed += 1; print(f'  ✗ {name}: want {want!r}, got {got!r}')


MD = ['# Title here', '* org item one', '- Which one is', '  wrapped on', '- Whatever else',
      '', 'The other direction: a', '  pattern here. Then more.', '', 'The model in four',
      'say Howitzer and foo, verbose', 'Does When set up a listener? Not quite.']

print('arguments of several words, and that start with punctuation')
expect('_# : the row that starts with #', ['# Title here '], MD, '_#')
expect('_# Ti', ['# Title here '], MD, '_# Ti')
expect('^* org: a line start, the last word completed', ['* org '], MD, '^* org')
expect('^The oth: the words, the last completed', ['The other '], MD, '^The oth')
expect('_The oth: the row', ['The other direction: a '], MD, '_The oth')
expect('-Which one: the whole item', ['Which one is wrapped on '], MD, '-Which one')
expect('.The oth: the whole sentence (: ends one)', ['The other direction: '], MD, '.The oth')
expect('=Does Wh: the entity that starts so', ['Does When '], MD, '=Does Wh')
expect('^Wh: a line start past a list mark too', ['Which ', 'Whatever '], MD, '^Wh')

print('a mark after anything but a letter or digit')
for before, want in [('/=Do', ['Does When ']), ('x:^Th', ['The ']), ('(-Wh', ['Which one is wrapped on ']),
                     ('"=Do', ['Does When ']), ('x _# Ti', ['# Title here '])]:
    expect(before, want, MD, before)
expect('not after a letter: x=foo completes foo... as text', [], MD, 'x=foo')
expect('/command alone is the program\'s', 'program', MD, '/comp')

print('a mark with nothing of its kind matching is text')
expect('^How: no line starts so, the word completes, the ^ kept', ['^Howitzer '], MD, '^How')
expect('-verb: no item, -verbose', ['-verbose '], MD, '-verb')
expect('--verb: the second - is the mark, so --verbose', ['-verbose '], MD, '--verb')
expect('x==fo: the second = is the mark, so x==four, x==foo', ['=four ', '=foo '], MD, 'x==fo')
expect('=zz: nothing at all', [], MD, '=zz')

print('-- and ". " are text')
expect('re: "x" -- Wh: Wh completes as a word', ['Which ', 'Whatever '], MD, 're: "x" -- Wh')

print('sugar (SUGARS, @dabbrev-sugars)')
sugar = os.path.join(scratch, 'sugars')
open(sugar, 'w').write('# MARK TEXT\n§  ^%..$$\nx  not a mark\n=  not a new one\n')
OPTIONS['@dabbrev-sugars'] = sugar
expect('§The oth: the block from the line that starts so', ['The other direction: a pattern here. Then more. '], MD, '§The oth')
expect('  ... a letter is no sugar mark: xy completes as a word', ['xylophone '], MD + ['xylophone'], 'xy')
expect('  ... nor one of the marks', ['Does When '], MD, '=Does Wh')
expect('_ is one too, built in', ['# Title here '], MD, '_#')
del OPTIONS['@dabbrev-sugars']

print('chains: several operators in one press, what is between them kept')
LISTS = ['1. First thing', '2. Second thing', '- Which one', '- Whatever else', '', 'Does When set up?']
expect('1. 2.', ['1. First thing 2. Second thing '], LISTS, '1. 2.')
expect('1., 2.: the joiner as typed', ['1. First thing, 2. Second thing '], LISTS, '1., 2.')
expect('-Wh; =Does', ['Which one; Does When '], LISTS, '-Wh; =Does')
expect('the last one cycles (M-/)', ['1. First thing, Which one ', '1. First thing, Whatever else '], LISTS, '1., -Wh')
expect('a plain word breaks a chain: only the last expands', ['2. Second thing '], LISTS, '1. and 2.')
expect('a non-last argument is one word: "-Wh one, 2." is the last only', ['2. Second thing '], LISTS, '-Wh one, 2.')
SNIP = os.path.join(scratch, 'snippets')
open(SNIP, 'w').write('rr  re: "|" --\\s\n')
OPTIONS['@dabbrev-snippets'] = SNIP
expect(',r=Does: the snippet, then the entity in its quotes', ['re: "Does When" -- '], LISTS, ',r=Does')
pane = Pane(LISTS, ',r=Does')
found = d.Screen().typed(pane, 'tab')
alt = d.Screen().complete(pane, *found)[0]
expect_back = alt.get('back')
passed, failed = (passed + 1, failed) if expect_back == 5 else (passed, failed + 1)
print('  ✓' if expect_back == 5 else f'  ✗ (back {expect_back})', '  ... the cursor before the snippet\'s closing quote')
del OPTIONS['@dabbrev-snippets']

open(SNIP, 'w').write('re  re: "|" --\\s\nrr  re: "|" --\\s\nrs  rest\n')
OPTIONS['@dabbrev-snippets'] = SNIP
expect(',re: the snippet named re', ['re: "" -- '], LISTS, ',re')
expect(',r: two names for one text are one alternative', ['re: "" -- ', 'rest'], LISTS, ',r', 'expand')
del OPTIONS['@dabbrev-snippets']

print('\\: literal text up to the next operator')
expect('1. \\then 2.', ['1. First thing then 2. Second thing '], LISTS, '1. \\then 2.')
expect('=Does \\and then -Wh', ['Does When and then Which one '], LISTS, '=Does \\and then -Wh')

print('ends that are places: ..^WORD the line that starts so, ..-WORD (..-) the list item')
expect('^The oth..^The: up to and with the next line starting The', ['The other direction: a pattern here. Then more. The '], MD, '^The oth..^The')
expect('^The oth...^The: up to it', ['The other direction: a pattern here. Then more. '], MD, '^The oth...^The')
expect('-Which...-: up to the next item', ['Which one is wrapped on '], MD, '-Which...-')
expect('-Which..-Wha: up to and with Whatever', ['Which one is wrapped on - Whatever '], MD, '-Which..-Wha')

print('explain')
pane = Pane(LISTS, '')
lines = d.explain(pane, '1., -Wh')
want = ["number '1.' then ', '", "mark - 'Wh'"]
ok = all(any(w in l for l in lines) for w in want) and any('Which one' in l for l in lines)
passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
print('  ✓ the units, joiners and what each takes' if ok else f'  ✗ explain: {lines}')

print(f'{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
EOF
