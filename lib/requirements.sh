# What tmux-tools needs, for install and tmux-tools.tmux (sourced by bash).
#
# tmux_tools_problems [TMUX_VERSION] — print what is missing, a line each,
# and fail if anything is; on success, print notes (what works less well).
# TMUX_VERSION is the server's (#{version}); by default tmux -V's.

TMUX_TOOLS_TMUX_MIN=3.3
TMUX_TOOLS_PYTHON_MIN=3.9

# version_at_least HAVE WANT — 3.3a, next-3.6 and 3.10 compare as numbers.
tmux_tools_version_at_least() {
    local have want
    have="$(printf '%s' "$1" | sed -E 's/^[^0-9]*([0-9]+)\.([0-9]+).*/\1 \2/')"
    want="$(printf '%s' "$2" | sed -E 's/^([0-9]+)\.([0-9]+).*/\1 \2/')"
    set -- $have $want
    [ "$#" -eq 4 ] || return 1
    [ "$1" -gt "$3" ] || { [ "$1" -eq "$3" ] && [ "$2" -ge "$4" ]; }
}

tmux_tools_problems() {
    local v="${1:-}" bad=0 out='' notes=''
    if [ -z "$v" ]; then
        if command -v tmux >/dev/null 2>&1; then
            v="$(tmux -V 2>/dev/null | sed 's/^tmux //')"
        else
            out="tmux is not installed"; bad=1
        fi
    fi
    if [ -n "$v" ]; then
        if ! tmux_tools_version_at_least "$v" "$TMUX_TOOLS_TMUX_MIN"; then
            out="${out:+$out$'\n'}tmux is $v; tmux-tools needs $TMUX_TOOLS_TMUX_MIN or newer"; bad=1
        elif ! tmux_tools_version_at_least "$v" 3.4; then
            notes="tmux is $v: link acts on links (OSC 8) from tmux 3.4 on; until then on the things on screen only"
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        out="${out:+$out$'\n'}python3 is not installed; every tool but quote-reply and scroll needs it"; bad=1
    elif ! python3 -c "import sys; sys.exit(sys.version_info < (${TMUX_TOOLS_PYTHON_MIN/./, }))" 2>/dev/null; then
        local pv; pv="$(python3 -V 2>&1 | sed 's/^Python //')"
        out="${out:+$out$'\n'}python3 is ${pv:-of an unknown version}; tmux-tools needs $TMUX_TOOLS_PYTHON_MIN or newer"; bad=1
    fi
    if [ "$bad" -eq 1 ]; then printf '%s\n' "$out"; return 1; fi
    [ -n "$notes" ] && printf '%s\n' "$notes"
    return 0
}
