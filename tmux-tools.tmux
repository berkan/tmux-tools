#!/usr/bin/env bash
# tmux-tools — run by tpm when tmux starts (or from tmux.conf:
#   run-shell /path/to/tmux-tools/tmux-tools.tmux
# ). Binds the tools named in the @tmux-tools option, each with its own
# `bind` (default: all of them; '' for none):
#   set -g @tmux-tools 'dabbrev link jump-click expand-region quote-reply slurp scroll electric-pair'
# Set the tools' own options (README.md) before this runs.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/requirements.sh"
# Short of what the tools need: bind nothing and say why, now to a client
# attached (a config sourced again) and to the next one to attach or make a
# session (none is attached while tmux starts).
if ! problems="$(tmux_tools_problems "$(tmux display-message -p '#{version}')")"; then
    msg="tmux-tools: not bound: $(printf '%s\n' "$problems" | awk 'NR > 1 { printf "; " } { printf "%s", $0 }') (any key to close)"
    msg="${msg//\"/\'}"
    tmux display-message -d 0 "$msg" 2>/dev/null || true
    for hook in client-attached client-session-changed; do
        tmux set-hook -g "$hook[77]" "display-message -d 0 \"$msg\" ; set-hook -gu client-attached[77] ; set-hook -gu client-session-changed[77]"
    done
    exit 0
fi
for hook in client-attached client-session-changed; do
    tmux set-hook -gu "$hook[77]" 2>/dev/null || true
done
if tmux show-options -gq @tmux-tools | grep -q .; then
    tools=$(tmux show-options -gqv @tmux-tools)
else
    tools='dabbrev link jump-click expand-region quote-reply slurp scroll electric-pair'
fi
# electric-pair last: its Tab wraps the Tab bound before it (dabbrev's).
case " $tools " in
    *' electric-pair '*) tools="$(printf '%s\n' $tools | grep -vx electric-pair | tr '\n' ' ') electric-pair" ;;
esac
for tool in $tools; do
    if [ -x "$DIR/bin/tmux-$tool" ]; then
        "$DIR/bin/tmux-$tool" bind
    else
        tmux display-message "tmux-tools: no tool called $tool"
    fi
done
