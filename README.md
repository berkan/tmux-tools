# tmux-tools

Keyboard tools for tmux, for reaching what is on the screen: complete from it,
jump to it, copy it, open it. They work in any program that takes typed keys,
and were made for typing into terminal agents (Claude Code, Codex, pi): quoting
their answers back, pulling a passage into the prompt, opening a file they
named.

| tool | what it does |
|---|---|
| `dabbrev` | completes the word before the cursor from the screen, like Emacs' `M-/`, and a small language for pulling in more: a line, a list item, a sentence, a passage, a snippet |
| `link` | in copy mode, acts on the link (OSC 8) or the thing under the cursor: open it, copy, paste or quote its full target |
| `jump-click` | jump to any place on screen by keyboard; in a prompt the program's own cursor moves there |
| `expand-region` | in copy mode, grow the selection to the next larger region (word, path, quotes, brackets, line, paragraph), like Emacs' expand-region |
| `quote-reply` | paste the newest copy as `re: "…" -- `, to quote an answer back to an agent |
| `electric-pair` | type brackets and quotes in pairs, like Emacs' `electric-pair-mode`: `(` gives `(\|)`, `)` or Tab steps over the one after the cursor, Backspace takes an empty pair |

## Requirements

- tmux 3.4 or newer (3.5 for `link` to read links without leaving copy mode)
- python3 (`quote-reply` is plain sh)
- for `dabbrev`'s `M-/` and `M-?`: a terminal that sends them. In Ghostty, to
  have Cmd+/ and Cmd+Shift+/ do it:

  ```
  keybind = cmd+/=text:\x1b/
  keybind = cmd+shift+/=text:\x1b?
  ```

## Install

With [tpm](https://github.com/tmux-plugins/tpm), in `~/.tmux.conf`:

```tmux
set -g @plugin 'berkan/tmux-tools'
```

then `prefix I`. tpm runs `tmux-tools.tmux`, which binds every tool.

By hand: clone the repository anywhere and add to `~/.tmux.conf`

```tmux
run-shell ~/path/to/tmux-tools/tmux-tools.tmux
```

One tool alone: each binds its own keys, so

```tmux
run-shell '~/path/to/tmux-tools/bin/tmux-dabbrev bind'
```

Set a tool's options (below) before the line that binds it.

### Choosing tools

```tmux
set -g @tmux-tools 'dabbrev link jump-click'    # unset: all of them; '' for none
```

`link` uses `dabbrev`'s idea of what a thing on screen is (an entity, below)
when `bin/tmux-dabbrev` is beside it, whether `dabbrev` is bound or not;
without it, `link` acts on links only.

## Keys and options

Each option is a tmux option, set with `set -g`. Defaults in brackets.

### Shared

| option | |
|---|---|
| `@tmux-tools-pairs` | the pairs of brackets and quotes, two characters each [``` ()[]{}""''`` ```]; e.g. ``` '()[]{}""''``<>' ```. electric-pair types them in pairs; dabbrev closes a completion typed after an opener with its pair, and puts `LEFT \|(` between one; expand-region takes the brackets among them (pairs of two different characters) as regions |

### dabbrev

| key | does |
|---|---|
| `M-/` | the best completion; again, the next one; past the last, what was typed |
| `Tab` (in the programs below) | the same first completion; again, the word that follows it on screen, and so on |
| `M-?` | take back the last press |
| `Tab` after `` `code` `` | runs the code, its output in place of it: `` `date +%F` `` → `2026-10-25` (below) |

| option | |
|---|---|
| `@dabbrev-key`, `@dabbrev-undo-key` | the keys [`M-/`, `M-?`] |
| `@dabbrev-tab-commands` | programs in which Tab completes, by `#{pane_current_command}`, each a regular expression for the whole name [`claude codex pi node agy gemini [0-9.]+`: Claude Code on macOS is named for its version]; `''` leaves Tab alone |
| `@dabbrev-order` | the order of words that rank alike [`middle`: nearest the middle of the screen]; also `frequent`, `cursor`, `top` |
| `@dabbrev-span-order` | the same for entities [`middle`] |
| `@dabbrev-entities` | what counts as one thing on screen [`coloured camelcase capitalised`]: runs of text in a style of their own, CamelCase words, runs of Capitalised Words; `''` for none |
| `@dabbrev-ruby-ranges` | `..` takes the end and `...` stops before it, as Ruby's ranges [on]; `off`: both take it |
| `@dabbrev-snippets` | the snippets file [`~/.config/tmux-dabbrev/snippets`] |
| `@dabbrev-sugars` | the sugar file [`~/.config/tmux-dabbrev/sugars`] |
| `@dabbrev-spaced-marks` | the marks whose argument may also be one space after them, as `^ The` or `\ some text` [none]; for marks that do not come before a space in ordinary text, such as `'^_\'` (with `-` `.` `=` `,`, prose like `- item` would be read as an operator) |
| `@dabbrev-eval` | which `` `code` `` + Tab runs [`on`: any; with no engine named, `sh`]; `engines`: only with an engine named (`` `sh ls` ``); `off`: none |
| `@dabbrev-eval-timeout` | the seconds code may run [`5`]; then it is stopped, children and all |
| `@dabbrev-engines` | the engines file [`~/.config/tmux-dabbrev/engines`] |
| `@dabbrev-pipe-completion` | right after a completion (`_h` + Tab, then `\|(` + Tab), the pipe's LEFT is that completion, whole: `(hello world)` [on]; `off`: as anywhere else (below) |

Entities come before words. A completion after an opening quote or bracket
is closed with its pair (`"hel` → `"hello" `; the pairs of `@tmux-tools-pairs`).

### link

In copy mode (copy-mode-vi), with nothing selected — as where `jump-click`
lands:

| key | does |
|---|---|
| `o`, `Enter` | open the link: a file or folder in `$VISUAL` (else `$EDITOR`, else vi) in a popup; another link with the opener |
| `y`, `p`, `r` | copy, paste, quote (`re: "…" -- `) the link's full target (a file link's path), or else the entity under the cursor |

With a selection they do what tmux does (`r` quotes it).

| option | |
|---|---|
| `@link-opener` | the command that opens web links [unset: `open`, else `xdg-open`]; `''`: none, the link is copied instead |

Claude Code shows a short path (`drafts/x.md`) for the file it links
(`file:///Users/me/notes/drafts/x.md`); `link` takes the full one.

### jump-click

| key | does |
|---|---|
| `prefix` then the key, a character, the label | jump there: a place the program's cursor can reach (red) moves that cursor (a click, or arrow keys); any other (blue) goes there in copy mode with a selection begun |

`^` as the character labels the start of each line. While selecting, a
second jump moves the selection's end.

| option | |
|---|---|
| `@jump-click-key` | the key(s) after the prefix [`C-j`]; several separated by spaces |

### expand-region

| key (copy mode) | does |
|---|---|
| `=` | grow the selection to the next larger region |
| `-` | shrink it back |

| option | |
|---|---|
| `@expand-region-expand-key`, `@expand-region-shrink-key` | the keys [`=`, `-`] |
| `@expand-region-rules` | a rules file [`~/.config/tmux-expand-region/rules`]; `tmux-expand-region rules` prints the rules in effect |

### electric-pair

In the programs below, without the prefix. tmux cannot see a program's
input, so it goes by what the screen shows either side of the cursor.

| key | does |
|---|---|
| an opener `(` `[` `{` | types the pair, the cursor between: `(\|)`; not before a letter or digit, nor after `\` |
| a quote `"` `'` `` ` `` | the same, and not after a letter or digit either (`don't`) |
| a closer, or a quote, with the same right after the cursor | steps over it |
| a closer right where dabbrev's Tab has just closed the completion with it | nothing, once: `(hel` + Tab gives `(hello) `, and a `)` typed out of habit is not a second |
| `BSpace` in an empty pair it typed | takes both |
| `Tab` with a closer right after the cursor | steps over it: `(hello\|)` to `(hello)\|`; elsewhere Tab does what it did (dabbrev's completion); a closing backtick is left to dabbrev, to run the code before it (unless `@dabbrev-eval` is `off`) |

| option | |
|---|---|
| `@tmux-tools-pairs` | the pairs (Shared, above) |
| `@electric-pair-commands` | programs it works in, as `@dabbrev-tab-commands` [the same]; `''` binds nothing |
| `@electric-pair-tab` | `off`: Tab before a closer completes too [on: it steps over]; read at each press, so `tmux set -g @electric-pair-tab off` applies at once |

With Tab stepping over, `(hel|)` + Tab steps out rather than completing
`hel`; `M-/` completes it. With it off, Tab completes there, ending against
the closer, `(hello|)`, and Tab again adds the next word; `)` steps out.
electric-pair binds Tab around whatever Tab was bound to, so
`tmux-tools.tmux` binds it after the other tools.

Typing stays quick: a closer, and Backspace but in an empty pair, are
decided by tmux itself, with no process; an opener or quote that may pair,
or Backspace in an empty pair, takes some 30–45 ms. Keys typed meanwhile
wait, in order. An opener or quote goes in before its closer is decided, so
keys typed just before it that the program has not shown yet do not mislead
it (`don't` typed fast).

### quote-reply

| option | |
|---|---|
| `@quote-reply-key` | the key after the prefix that pastes the newest copy as `re: "…" -- ` [none] |

## Personalising

### Snippets (dabbrev)

`,name` + Tab types the snippet; `,n` + `M-/` cycles those starting `n`, `,`
alone all of them. The file (`@dabbrev-snippets`), one a line:

```
# NAME  TEXT
re      re: "|" --\s
sig     Best,\nAda
```

`|` is where the cursor goes, `\n` a line break (pasted, so the program does
not take it as Enter), `\s` a space (for a trailing one), `\|` and `\\` a bar
and a backslash. Names are letters, digits and `_`. The file is read at each
`,name` completion, so edits apply at once.

### Running code (dabbrev)

`` `code` `` + Tab runs the code and puts what it prints in place of it,
backticks and all, the line breaks at its end left out (several lines go
in as a paste, not as Enter). Tab right before the closing backtick, where
electric-pair leaves the cursor, does it too. The first word may name an
engine, which runs the rest: `` `py 2**10` `` → `1024`, `` `js 1+2` `` → `3`;
with none named, `sh` runs it all (`@dabbrev-eval`). It runs in the pane's
folder, wherever tmux runs (inside the container, in ppi). On a failure the
code stays and the error shows in the status line; `M-?` takes a result
back (not what the code did).

Built in: `sh` (`sh -c {}`), `js` (`node -p {}`), `py` (python3, `eval` of
the code, printed). The file (`@dabbrev-engines`) adds to them or replaces
them, one a line; `{}` is the code as one argument, without it the code goes
to the command's stdin:

```
# NAME  COMMAND
rb      ruby -e "p eval(ARGV[0])" {}
bc      bc -l
```

Code in a prompt is easy to run by accident: Tab right after a code span
(`` `git push --force` ``) runs it. `@dabbrev-eval engines` runs only spans
that name their engine. Only the cursor's row is read, so code must be on
one row.

### Sugar (dabbrev)

A mark of your own that stands for an operator, `%` its argument. Built in:
`_` is `^%..$` (the row that starts so). The file (`@dabbrev-sugars`):

```
# MARK  WHAT IT STANDS FOR
§       ^%..$$
```

A mark is one character that is not a letter, digit or one of `^ - . = , \ #`.

### Regions (expand-region)

The rules file (`@expand-region-rules`) adds to or replaces the built-in
rules, one a line:

```
# NAME  regex  PATTERN      each match a region (and each named group in it)
ticket  regex  [A-Z]+-\d+
-email                      drop the rule called email
```

## dabbrev's language

What is typed before the cursor is read for operators; with none, the last
word is completed from the screen. An operator's mark counts after anything
but a letter or digit (a space, a quote, a bracket, `/`), and its argument
touches it (or is one space after it, for the marks in
`@dabbrev-spaced-marks`). The same holds for `,name` and `\text`.

| typed | Tab gives |
|---|---|
| `wor` | a word on screen starting so; Tab again, the words after it |
| `^The oth` | the words at a line's start (`^#`, `^*` for headings and org items) |
| `_The oth` | the whole row that starts so |
| `-Which` | the whole list item that starts so |
| `.The` | the whole sentence that starts so (to `.` `!` `?` or `:`) |
| `=Does` | an entity that starts so (`=` gives the longer first) |
| `2.` | the list item numbered 2 |
| `keep them ..cons` | from where `keep them` is on screen up to and with `consumes` |
| `^T..$$` | from a line starting `T` to the end of its block (a blank line) |
| `-F....` | from a list item starting `F` to the end of its sentence, without the full stop |
| `,re` | the snippet `re` |
| `_Sn \| ,re` | the row starting `Sn`, put in the snippet `re` |
| `hello \|(` | `(hello)`: between the pair, for each of `@tmux-tools-pairs` |

Ends after `..` (with the end) or `...` (up to it): a word, `$` (the line's
end), `$$` (the block's), `.` (the sentence's), `?`, `!`, `^Wh` (the next line
starting `Wh`), `-Wh` or `-` (the next list item).

Several in one press make a chain, joined by what you type between them
(spaces and `, ; :`): `1., 2.` gives both items with `, ` between; `,re=Does`
puts the entity in the snippet's quotes. `\text` is text as it is, up to the
next operator. All but the last take a one-word argument; a word of plain text
between them ends the chain.

`LEFT | ,name` puts LEFT into the snippet `name`, where its `|` is (with
none, at its end), the cursor after it all: `Snapshot | ,re` gives
`re: "Snapshot" -- `. LEFT is the operator or chain right before the `|`,
expanded (`^Sn | ,re`, `1. 2. | ,re`; `M-/` cycles it), or a `\text` (words
and all), or else the one word before the `|`, as typed. But right after a
completion it is the completion, whole, with the quotes or brackets it was
closed in (`@dabbrev-pipe-completion`).

`LEFT |(` puts LEFT between a pair the same way: `hello |(` gives `(hello)`,
`_Sn |"` the row in quotes, for each of `@tmux-tools-pairs`. When the closer is already after the cursor
(electric-pair typed it with the opener), the text ends against it, the
cursor before it, so typing the closer steps over it.

An operator with nothing on screen to match is text: its word completes as
any (`^Howitzer`). `M-/` cycles the last operator's matches; `M-?` takes the
press back.

To see how something is read and what each part would take:

```
tmux-dabbrev explain '1., -Wh' [PANE]
```

## Tests

```
bash tests/dabbrev-logic.test.sh   # the language, no tmux: a second
bash tests/dabbrev.test.sh         # typing into a real pane: minutes
bash tests/link.test.sh
bash tests/jump-click.test.sh
bash tests/expand-region.test.sh
bash tests/electric-pair.test.sh
bash tests/entry.test.sh           # tmux-tools.tmux
```

Each runs its own scratch tmux server and touches nothing of yours.

## Licence

MIT — see LICENSE.
