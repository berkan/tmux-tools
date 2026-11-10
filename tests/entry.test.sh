#!/usr/bin/env bash
# Tests for tmux-tools.tmux, what tpm runs: it binds the tools named in
# @tmux-tools (all when unset, none when ''). A scratch tmux server; needs
# tmux and python3.
#
#   bash tests/entry.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/../tmux-tools.tmux"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-tools-entry.XXXXXX")" && pwd)"
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
# bound — which tools have keys: dabbrev link jump-click expand-region quote-reply slurp scroll electric-pair.
bound() {
    local keys out=''
    keys=$(tmux list-keys)
    for t in dabbrev link jump-click expand-region quote-reply slurp scroll electric-pair; do
        grep -qE "tmux-$t|@$t-" <<<"$keys" && out+="$t "
    done
    echo "$out"
}
fresh() { tmux kill-server 2>/dev/null || true; tmux -f /dev/null new-session -d 'sleep 600'; }

fresh
tmux set -g @quote-reply-key r
bash "$ENTRY"
expect "@tmux-tools unset: every tool" 'dabbrev link jump-click expand-region quote-reply slurp scroll electric-pair ' "$(bound)"
fresh
tmux set -g @tmux-tools 'dabbrev link'
bash "$ENTRY"
expect "@tmux-tools 'dabbrev link': those only" 'dabbrev link ' "$(bound)"
fresh
tmux set -g @tmux-tools ''
bash "$ENTRY"
expect "@tmux-tools '': none" '' "$(bound)"
fresh
bash "$ENTRY"
expect "quote-reply binds nothing without @quote-reply-key" 'dabbrev link jump-click expand-region slurp scroll electric-pair ' "$(bound)"
fresh
tmux set -g @tmux-tools 'electric-pair dabbrev'
bash "$ENTRY"
expect "electric-pair binds last, so its Tab wraps dabbrev's whatever the order" 1 \
    "$(tmux list-keys -T root Tab | grep -F 'electric-pair-tab' | grep -cF 'tmux-dabbrev tab')"

# What is missing is told on the next attach or new session (none may be
# attached while the config runs), and nothing is bound.
mkdir -p "$SCRATCH/old"
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/old/python3"; chmod +x "$SCRATCH/old/python3"
fresh
PATH="$SCRATCH/old:$PATH" bash "$ENTRY" || true
expect "an old python3: nothing is bound" '' "$(bound)"
expect "  ... and the next attach is told so" 1 \
    "$(tmux show-hooks -g client-attached | grep -F 'display-message' | grep -cF 'python3')"
expect "  ... as is a new session" 1 \
    "$(tmux show-hooks -g client-session-changed | grep -F 'display-message' | grep -cF 'python3')"
fresh
bash "$ENTRY"
expect "with what is needed, no such hook" 0 "$(tmux show-hooks -g | grep -cF 'tmux-tools:' || true)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
