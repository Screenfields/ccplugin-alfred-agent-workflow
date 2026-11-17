#!/usr/bin/env bash
# SessionStart hook (CCW-220): refresh a stale installed alfred-wake.
#
# A plugin update does not refresh the alfred-wake a lead launches by name from
# PATH (a symlink into an old cache dir, or on Windows Git Bash a copy). At
# startup and resume this compares ${ALFRED_WAKE_BIN_DIR:-$HOME/.local/bin}/alfred-wake
# with this plugin's bin/alfred-wake and, when it is stale, runs the plugin's
# own `install`. Silent when all is well. When the refresh fails it adds one
# line of context. It never creates a link where none exists, never runs the
# PATH bridge, makes no network call, and always exits 0.
# ALFRED_WAKE_LINK_CHECK=0 switches it off. See docs/baseline/wake-install-refresh.md.
set -u

[ "${ALFRED_WAKE_LINK_CHECK:-1}" = "0" ] && exit 0

input=$(cat)
printf '%s' "$input" | jq -s -e 'length == 1' >/dev/null 2>&1 || exit 0
field() { printf '%s' "$input" | jq -r ".$1 // empty" 2>/dev/null; }
case "$(field source)" in startup | resume) ;; *) exit 0 ;; esac
cwd=$(field cwd)
[ -n "$cwd" ] || cwd="$PWD"
jq -e '.agent_id // empty' "$cwd/.alfred/config.json" >/dev/null 2>&1 || exit 0

here=$(cd "$(dirname "$0")" && pwd)
plugin_bin=$(readlink -f "$here/../bin/alfred-wake" 2>/dev/null) || exit 0
{ [ -r "$plugin_bin" ] && [ -x "$plugin_bin" ]; } || exit 0
ver_of() { sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -1; }
plugin_ver=$(ver_of "$plugin_bin")
[ -n "$plugin_ver" ] || exit 0
link="${ALFRED_WAKE_BIN_DIR:-$HOME/.local/bin}/alfred-wake"

[ -d "$link" ] && exit 0
[ -f "$link" ] || [ -L "$link" ] || exit 0

current() {
  if [ -L "$link" ]; then
    [ "$(readlink -f "$link" 2>/dev/null)" = "$plugin_bin" ]
  else
    [ -f "$link" ] && cmp -s "$link" "$plugin_bin"
  fi
}
current && exit 0

link_ver=$(ver_of "$link")
[ -n "$link_ver" ] || link_ver=unknown

# Direction guard: never replace a link or copy that is newer than the plugin's.
# `unknown` counts as older; sort -V only sees numeric versions.
if [ "$link_ver" != unknown ]; then
  top=$(printf '%s\n%s\n' "$link_ver" "$plugin_ver" | sort -V | tail -1)
  [ "$top" = "$plugin_ver" ] || exit 0
fi

# Clobber guard: a regular file is replaced only when it looks like alfred-wake.
refresh=1
if [ ! -L "$link" ]; then
  if [ "$link_ver" = unknown ] || ! grep -q 'alfred-wake' "$link" 2>/dev/null; then
    refresh=0
  fi
fi

if [ "$refresh" = 1 ]; then
  timeout -k 1 2 "$plugin_bin" install >/dev/null 2>&1 </dev/null
  current && exit 0
  link_ver=$(ver_of "$link")
  [ -n "$link_ver" ] || link_ver=unknown
  if [ ! -e "$link" ] && [ ! -L "$link" ]; then link_ver=missing; fi
fi

msg="alfred-wake at $link ($link_ver) is not the installed plugin's ($plugin_ver) and was not refreshed; run \"$plugin_bin install\" if that file should be replaced, then tell the owner in one line."
jq -n --arg m "$msg" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
exit 0
