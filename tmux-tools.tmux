#!/usr/bin/env bash
# tmux-tools — run by tpm when tmux starts (or from tmux.conf:
#   run-shell /path/to/tmux-tools/tmux-tools.tmux
# ). Binds the tools named in the @tmux-tools option, each with its own
# `bind` (default: all of them; '' for none):
#   set -g @tmux-tools 'dabbrev link jump-click expand-region quote-reply electric-pair'
# Set the tools' own options (README.md) before this runs.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if tmux show-options -gq @tmux-tools | grep -q .; then
    tools=$(tmux show-options -gqv @tmux-tools)
else
    tools='dabbrev link jump-click expand-region quote-reply electric-pair'
fi
for tool in $tools; do
    if [ -x "$DIR/bin/tmux-$tool" ]; then
        "$DIR/bin/tmux-$tool" bind
    else
        tmux display-message "tmux-tools: no tool called $tool"
    fi
done
