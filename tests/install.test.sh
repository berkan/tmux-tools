#!/usr/bin/env bash
# Tests for ./install: it checks tmux and python3, adds tmux-tools to the
# tmux config tmux reads, and binds it in a running server. A scratch HOME
# and tmux server; touches nothing of the user's.
#
#   bash tests/install.test.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/tmux-tools-install.XXXXXX")" && pwd)"
export TMUX_TMPDIR="$SCRATCH"
unset TMUX XDG_CONFIG_HOME
trap 'HOME="$SCRATCH/home" tmux kill-server 2>/dev/null || true; rm -rf "$SCRATCH"' EXIT

pass=0
fail=0
expect() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "  ✓ $name"
    else fail=$((fail + 1)); echo "  ✗ $name: want '$want', got '$got'"; fi
}
# A fresh home, no server.
fresh() {
    HOME="$SCRATCH/home" tmux kill-server 2>/dev/null || true
    rm -rf "$SCRATCH/home"; mkdir -p "$SCRATCH/home"
}
inst() { HOME="$SCRATCH/home" "$ROOT/install" "$@"; }
h() { HOME="$SCRATCH/home" "$@"; }
# How many of tmux-tools' keys the server has.
keys() { h tmux list-keys | grep -cF "$ROOT/bin/tmux-" || true; }
lines() { grep -cF "$ROOT/tmux-tools.tmux" "$1" || true; }

echo "no config, no server"
fresh
out=$(inst 2>&1)
expect "~/.tmux.conf is made, with the line" 1 "$(lines "$SCRATCH/home/.tmux.conf")"
expect "  ... it says where" yes "$(grep -qF "$SCRATCH/home/.tmux.conf" <<<"$out" && echo yes || echo no)"
h tmux new-session -d -x 80 -y 10; sleep 1
expect "a server started after has the keys" yes "$([ "$(keys)" -gt 10 ] && echo yes || echo no)"
inst >/dev/null 2>&1
expect "run again: the line is not added twice" 1 "$(lines "$SCRATCH/home/.tmux.conf")"

echo "an XDG config"
fresh
mkdir -p "$SCRATCH/home/.config/tmux"; echo 'set -g @mine 1' > "$SCRATCH/home/.config/tmux/tmux.conf"
inst >/dev/null 2>&1
expect "the line goes in the file tmux reads" 1 "$(lines "$SCRATCH/home/.config/tmux/tmux.conf")"
expect "  ... after what was there" 'set -g @mine 1' "$(head -1 "$SCRATCH/home/.config/tmux/tmux.conf")"
expect "  ... and no ~/.tmux.conf is made" no "$([ -e "$SCRATCH/home/.tmux.conf" ] && echo yes || echo no)"

echo "both: the last tmux reads, so the options set before it apply"
fresh
mkdir -p "$SCRATCH/home/.config/tmux"; touch "$SCRATCH/home/.tmux.conf" "$SCRATCH/home/.config/tmux/tmux.conf"
inst >/dev/null 2>&1
expect "the XDG one, read last" "0 1" "$(lines "$SCRATCH/home/.tmux.conf") $(lines "$SCRATCH/home/.config/tmux/tmux.conf")"

echo "already there by tpm"
fresh
printf '%s\n' "set -g @plugin 'berkan/tmux-tools'" "run '~/.tmux/plugins/tpm/tpm'" > "$SCRATCH/home/.tmux.conf"
out=$(inst 2>&1)
expect "not added again" 0 "$(lines "$SCRATCH/home/.tmux.conf")"
expect "  ... it says it is there" yes "$(grep -qi 'already' <<<"$out" && echo yes || echo no)"

echo "a running server"
fresh
# A config that is not safe to source twice: each time, another window.
echo 'new-window' > "$SCRATCH/home/.tmux.conf"
h tmux new-session -d -x 80 -y 10; sleep 0.5
windows=$(h tmux list-windows | wc -l | tr -d ' ')
out=$(inst 2>&1)
expect "its keys are bound now, no restart" yes "$([ "$(keys)" -gt 10 ] && echo yes || echo no)"
expect "  ... without sourcing the config again" "$windows" "$(h tmux list-windows | wc -l | tr -d ' ')"
expect "  ... it says what to try" yes "$(grep -qF 'M-/' <<<"$out" && echo yes || echo no)"

echo "--conf FILE"
fresh
inst --conf "$SCRATCH/home/my.conf" >/dev/null 2>&1
expect "the line goes in FILE" 1 "$(lines "$SCRATCH/home/my.conf")"

echo "--remove"
inst --remove --conf "$SCRATCH/home/my.conf" >/dev/null 2>&1
expect "the lines it added are gone" "0 0" "$(lines "$SCRATCH/home/my.conf") $(grep -c tmux-tools "$SCRATCH/home/my.conf" || true)"

echo "requirements"
mkdir -p "$SCRATCH/old"
real_tmux=$(command -v tmux)
printf '#!/bin/sh\n[ "$1" = -V ] && { echo "tmux 3.1c"; exit 0; }\nexec %s "$@"\n' "$real_tmux" > "$SCRATCH/old/tmux"
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/old/python3"
chmod +x "$SCRATCH/old/tmux" "$SCRATCH/old/python3"
fresh
set +e; out=$(PATH="$SCRATCH/old:$PATH" inst 2>&1); rc=$?; set -e
expect "an old tmux and python3: it stops" 1 "$rc"
expect "  ... naming tmux's version" yes "$(grep -qF '3.1c' <<<"$out" && echo yes || echo no)"
expect "  ... and python3's" yes "$(grep -qi 'python3' <<<"$out" && echo yes || echo no)"
expect "  ... and changes nothing" no "$([ -e "$SCRATCH/home/.tmux.conf" ] && echo yes || echo no)"
set +e; inst --check >/dev/null 2>&1; rc=$?; set -e
expect "--check with what is needed: 0" 0 "$rc"
expect "  ... and changes nothing" no "$([ -e "$SCRATCH/home/.tmux.conf" ] && echo yes || echo no)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
