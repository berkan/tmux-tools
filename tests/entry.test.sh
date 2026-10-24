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
# bound — which tools have keys: dabbrev link jump-click expand-region quote-reply electric-pair.
bound() {
    local keys out=''
    keys=$(tmux list-keys)
    for t in dabbrev link jump-click expand-region quote-reply electric-pair; do
        grep -q "tmux-$t" <<<"$keys" && out+="$t "
    done
    echo "$out"
}
fresh() { tmux kill-server 2>/dev/null || true; tmux -f /dev/null new-session -d 'sleep 600'; }

fresh
tmux set -g @quote-reply-key r
bash "$ENTRY"
expect "@tmux-tools unset: every tool" 'dabbrev link jump-click expand-region quote-reply electric-pair ' "$(bound)"
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
expect "quote-reply binds nothing without @quote-reply-key" 'dabbrev link jump-click expand-region electric-pair ' "$(bound)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
