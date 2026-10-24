# Instructions for agents working on tmux-tools

tmux-tools is a set of tmux tools (`bin/`), bound by `tmux-tools.tmux` (tpm's
entry). README.md is the user-facing documentation: keep it in step with
every change to keys, options, files or the dabbrev language.

- **Public repository** (github.com/berkan/tmux-tools): before committing,
  check that nothing private goes in — home paths, project or people's
  names from real screens, session ids, emails. Examples use neutral text.
- **Tests first** (red, then green). Suites, each on its own scratch tmux
  server, touching nothing of the user's:
  - `bash tests/dabbrev-logic.test.sh` — dabbrev's language on a stand-in
    pane, no tmux, under a second: the first place for a language change
  - `bash tests/dabbrev.test.sh` — typing into a real pane (minutes)
  - `bash tests/link.test.sh`, `bash tests/jump-click.test.sh`,
    `bash tests/expand-region.test.sh`, `bash tests/entry.test.sh`
  `link` also has to pass on tmux 3.4 (copy mode keeps no links there).
- **No dependency on any particular setup**: defaults under
  `~/.config/<tool>/`, options named after the tool (`@dabbrev-…`,
  `@link-…`), buffers named after the tool.
- **The user's own setup** (ppi, ~/dev/ppi) installs this with tpm. To make a
  change live there: push; then
  `~/.tmux/plugins/tpm/bin/update_plugins tmux-tools` in one ppi container
  (the plugin volume is shared) and on the host; then
  `tmux source-file ~/.pi/agent/ppi-tmux.conf` in each running container.
  ppi's `tests/tmux-config.test.sh` checks the bindings
  (`TMUX_TOOLS=~/dev/tmux-tools bash tests/tmux-config.test.sh` there).
- Commit each verified change (conventional messages, with the
  `Co-Authored-By` trailer the session gives).
