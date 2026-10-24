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
SHOWN = []                                      # what it showed in the status line
def tmux(*args, check=True):
    if args[0] == 'display-message' and '-p' not in args:
        SHOWN.append(args[-1])
    if args[:2] == ('show-options', '-gqv'):
        return OPTIONS.get(args[-1], '')
    if args[:2] == ('show-options', '-gq'):                    # set or not
        return f'{args[-1]} {OPTIONS[args[-1]]}\n' if args[-1] in OPTIONS else ''
    return ''
d.tmux = tmux


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
        self._sugars = self._marks = self._pairs = None

    def state(self, before=None):
        last = getattr(self, 'last', None)          # the state a test says the last press left
        return last if last and last['at'] == (self.before if before is None else before) else None


def alternatives(rows, before, key='tab', after='', last=None):
    pane = Pane(rows, before, after)
    pane.last = last
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

print('| : what is left of it into a snippet, at its |')
PIPED = ['Snapshot of the state', 'The model here', 'Then more', '1. First thing', '2. Second thing']
open(SNIP, 'w').write('rr  re: "|" --\\s\nend  tail\n')
OPTIONS['@dabbrev-snippets'] = SNIP
expect('Snapshot | ,r: a plain word as it is', ['re: "Snapshot" -- '], PIPED, 'Snapshot | ,r')
expect('  ... only the one word before it', ['re: "Snapshot" -- '], PIPED, 'hello world Snapshot | ,r')
expect('  ... spaces round | or none', ['re: "Snapshot" -- '], PIPED, 'Snapshot|,r')
expect('^Sn | ,r: an operator, expanded', ['re: "Snapshot" -- '], PIPED, '^Sn | ,r')
expect('_Sn | ,r: the row', ['re: "Snapshot of the state" -- '], PIPED, '_Sn | ,r')
expect('\\\\hello world | ,r: text of several words', ['re: "hello world" -- '], PIPED, '\\hello world | ,r')
expect('1. 2. | ,r: a chain, together', ['re: "1. First thing 2. Second thing" -- '], PIPED, '1. 2. | ,r')
expect('^Th | ,r: M-/ cycles what is left of it', ['re: "The" -- ', 're: "Then" -- '], PIPED, '^Th | ,r', 'expand')
expect('a snippet with no |: at its end', ['tailSnapshot'], PIPED, 'Snapshot | ,end')
expect('an operator before it that takes nothing: the word before the |', ['-Wzz and then re: "Snapshot" -- '], PIPED, '-Wzz and then Snapshot | ,r')
pane = Pane(PIPED, 'Snapshot | ,r')
found = d.BY_NAME['pipe'].typed(pane, 'tab')
names = [b.name for b in d.BACKENDS]
ok = found == (2, 'Snapshot | ,r') and names.index('pipe') < names.index('snippets')
passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
print('  ✓ it is the first backend, before the snippets' if ok else f'  ✗ first backend: {found}')
del OPTIONS['@dabbrev-snippets']

print('a space between a mark and its argument: none, but for the marks in @dabbrev-spaced-marks')
SPACED = ['The model here', 'see Thorn here', 'Snapshot of the state', '- Which one', 'Then more', '1. First thing', '2. Second thing']
open(SNIP, 'w').write('rr  re: "|" --\\s\n')
OPTIONS['@dabbrev-snippets'] = SNIP
def check(name, ok, got):
    global passed, failed
    passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
    print(f'  ✓ {name}' if ok else f'  ✗ {name}: got {got}')
got = alternatives(SPACED, '^ Th')
check('^ Th: by default not an operator, the word completes as any', 'Thorn ' in got, got)
expect('  ... \\ hello world | ,r: nor \\, the word before the |', ['re: "world" -- '], SPACED, '\\ hello world | ,r')
expect('  ... (,rr: a snippet counts after anything but a letter or digit, as the others', ['re: "" -- '], SPACED, '(,rr')
OPTIONS['@dabbrev-spaced-marks'] = '^_\\,'
expect('^ Th: with ^ listed, the same as ^Th', ['The '], SPACED, '^ Th')
expect('_ Sn: with _ listed', ['Snapshot of the state '], SPACED, '_ Sn')
expect('^ Sn..$: and before ..', ['Snapshot of the state '], SPACED, '^ Sn..$')
expect('-Wh..^Th: (as the end)', ['Which one Then '], SPACED, '-Wh..^Th')
expect('-Wh..^ Th: and as the end', ['Which one Then '], SPACED, '-Wh..^ Th')
expect('\\ hello world | ,r: with \\ listed', ['re: "hello world" -- '], SPACED, '\\ hello world | ,r')
expect('1. \\ then 2.: in a chain, the space not in the text', ['1. First thing then 2. Second thing '], SPACED, '1. \\ then 2.')
expect(', rr: with , listed', ['re: "" -- '], SPACED, ', rr')
got = alternatives(SPACED, '- Wh')
check('- Wh: - not listed, so text', 'Which ' in got, got)
got = alternatives(SPACED, '^  Th')
check('one space only: ^ and two is text', 'Thorn ' in got, got)
del OPTIONS['@dabbrev-spaced-marks'], OPTIONS['@dabbrev-snippets']

print('LEFT |( : LEFT between a pair (@tmux-tools-pairs)')
expect('hello |(: the word in the pair', ['(hello)'], PIPED, 'hello |(')
expect('  ... spaces round | or none', ['(hello)'], PIPED, 'hello|(')
expect('  ... a quote', ['"hello"'], PIPED, 'hello |"')
expect('  ... an operator, expanded', ['[Snapshot of the state]'], PIPED, '_Sn |[')
expect('  ... \\TEXT, words and all', ['{hello world}'], PIPED, '\\hello world |{')
expect('  ... M-/ cycles what is left of it', ['(The)', '(Then)'], PIPED, '^Th |(', 'expand')
got = alternatives(PIPED, 'hello |(', after=')')
check('  ... the closer after the cursor already (electric-pair typed it): ended against it', got == ['(hello'], got)
got = alternatives(PIPED, 'hello |<')
check('  ... not a pair: no surround', not got or '<hello>' not in got, got)
OPTIONS['@tmux-tools-pairs'] = '()<>'
expect('  ... the pairs from @tmux-tools-pairs', ['<hello>'], PIPED, 'hello |<')
del OPTIONS['@tmux-tools-pairs']

print('LEFT right after a completion: the whole completion (@dabbrev-pipe-completion, on by default)')
def last(at, start, text, **more):
    """The state a completion of TEXT typed from START leaves, the text left of the cursor AT."""
    return {'start': start, 'at': '> ' + at, 'levels': [{'none': '_h', 'alts': [{'text': text, **more}], 'index': 0}]}
HW = last('hello world ', 2, 'hello world ')
OPTIONS['@dabbrev-pipe-completion'] = 'off'
got = alternatives(PIPED, 'hello world |(', last=HW)
check('off: the word before the |', got == ['(world)'], got)
del OPTIONS['@dabbrev-pipe-completion']
OPTIONS['@dabbrev-snippets'] = SNIP
got = alternatives(PIPED, 'hello world |(', last=HW)
check('on (the default): _h + Tab, then |( + Tab: the completion in the pair', got == ['(hello world)'], got)
got = alternatives(PIPED, 'hello world | ,r', last=HW)
check('  ... and in a snippet', got == ['re: "hello world" -- '], got)
got = alternatives(PIPED, '"hello world" |(', last=last('"hello world" ', 3, 'hello world ') | {'close': '"'})
check('  ... a completion it closed: with its pair', got == ['("hello world")'], got)
got = alternatives(PIPED, 'hello world more |(', last=HW)
check('  ... text typed after it: as before, the word', got == ['(more)'], got)
got = alternatives(PIPED, 'hello world |(', last=last('hello world ', 2, 'hello world ', back=3))
check('  ... a completion that left the cursor inside it: as before', got == ['(world)'], got)
del OPTIONS['@dabbrev-snippets']

print('an opener before what is typed: the completion closed with its pair (@tmux-tools-pairs)')
closes = lambda before: d.closer('> ' + before, len('> ' + before) - 3, Pane([], before).pairs())
check('("hel: closed with "', closes('("hel') == '"', closes('("hel'))
check('<hel: < is not one of the pairs by default', closes('<hel') == '', closes('<hel'))
OPTIONS['@tmux-tools-pairs'] = '()<>'
check('  ... it is when the pairs have it', closes('<hel') == '>', closes('<hel'))
check('  ... and " is not, when they do not', closes('"hel') == '', closes('"hel'))
del OPTIONS['@tmux-tools-pairs']

print('`code` + Tab: what the code prints, in place of it')
import time
def not_run(name, before, key='tab'):
    taken = d.Eval().typed(Pane([], before), key)
    check(name, taken is None, taken)
expect('`echo hi`: run by sh', ['hi'], [], '`echo hi`')
expect('  ... after other text', ['say hi'], [], 'say `echo say hi`')
expect('  ... its output whole, but the line breaks at its end', ['a\nb'], [], "`printf 'a\\nb\\n\\n'`")
expect('  ... without its escape sequences (colour)', ['red'], [], "`printf '\\033[31mred\\033[0m'`")
expect("  ... in the pane's folder", ['/'], [], '`pwd`')
expect('`sh echo hi`: sh named', ['hi'], [], '`sh echo hi`')
expect('`py 2**10`: python', ['1024'], [], '`py 2**10`')
expect('`js 1+2`: node', ['3'], [], '`js 1+2`')
not_run('M-/ does not run it', '`echo hi`', key='expand')
not_run('`` (nothing inside): not code', '``')
not_run('```echo hi```: not code', '```echo hi```')
not_run('x`echo hi`: not after a letter', 'x`echo hi`')
SHOWN.clear()
expect('a failure: nothing', [], [], '`echo oops >&2; exit 3`')
check('  ... its error shown', any('oops' in m for m in SHOWN), SHOWN)
SHOWN.clear()
expect('  ... a program that is not there', [], [], '`no-such-program-here`')
check('  ... said so', any('not found' in m for m in SHOWN), SHOWN)
OPTIONS['@dabbrev-eval-timeout'] = '0.5'
SHOWN.clear()
t = time.monotonic()
expect('@dabbrev-eval-timeout 0.5: sleep 30 stopped', [], [], '`sleep 30 & sleep 30`')
check('  ... at once, its children too', time.monotonic() - t < 2, time.monotonic() - t)
check('  ... and said so', any('0.5' in m for m in SHOWN), SHOWN)
del OPTIONS['@dabbrev-eval-timeout']
ENGINES = os.path.join(scratch, 'engines')
with open(ENGINES, 'w') as f:
    f.write('# NAME  COMMAND\n'
            'up      tr a-z A-Z\n'
            'rev     python3 -c "import sys; print(sys.argv[1][::-1])" {}\n'
            'js      echo JS {}\n')
OPTIONS['@dabbrev-engines'] = ENGINES
expect('@dabbrev-engines: one with no {}: the code on its stdin', ['HELLO'], [], '`up hello`')
expect('  ... one with {}: the code as that argument', ['cba'], [], '`rev abc`')
expect('  ... one of the same name replaces the built-in', ['JS x'], [], '`js x`')
expect('  ... the built-ins stay', ['1024'], [], '`py 2**10`')
del OPTIONS['@dabbrev-engines']
OPTIONS['@dabbrev-eval'] = 'engines'
not_run("@dabbrev-eval engines: no engine named, it is not run", '`echo hi`')
expect('  ... an engine named, it is', ['hi'], [], '`sh echo hi`')
OPTIONS['@dabbrev-eval'] = 'off'
not_run('@dabbrev-eval off: not run', '`sh echo hi`')
del OPTIONS['@dabbrev-eval']

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
