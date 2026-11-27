# Plugin-version helpers (CCW-223). Tests hold no version literal: the previous
# version is read from origin/main, the current one from the working tree.
# Every function takes the repo root as $1. No network: origin/main must
# already be fetched (CI does it in .github/workflows/shellcheck.yml).

PV_SHAPE='^[0-9]+\.[0-9]+\.[0-9]+$'

# Working tree version, printed as written (may be malformed or empty).
plugin_version() {
  jq -r '.version // empty' "$1/.claude-plugin/plugin.json" 2>/dev/null
}

# Version on origin/main; prints nothing unless it is N.N.N.
previous_version() {
  local v
  v=$(git -C "$1" show refs/remotes/origin/main:.claude-plugin/plugin.json 2>/dev/null \
    | jq -r '.version' 2>/dev/null) || return 0
  if [[ "$v" =~ $PV_SHAPE ]]; then printf '%s\n' "$v"; fi
  return 0
}

# Decision table. Prints a reason or the offending lines.
# Returns 0 pass, 1 fail, 3 skip.
previous_version_leftovers() {
  local root=$1 prev cur out
  if ! git -C "$root" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' >/dev/null 2>&1; then
    if [ "${CI:-}" = true ]; then
      echo "origin/main does not resolve in CI (fetch it)"; return 1
    fi
    echo "no origin/main"; return 3
  fi
  prev=$(previous_version "$root")
  if [ -z "$prev" ]; then
    if [ "${CI:-}" = true ]; then
      echo "no previous version on origin/main in CI"; return 1
    fi
    echo "no previous version on origin/main"; return 3
  fi
  cur=$(plugin_version "$root")
  if [ "$prev" = "$cur" ]; then
    echo "version not bumped here"; return 3
  fi
  if out=$(cd "$root" && grep -rnwF -- "$prev" tests .claude-plugin); then
    echo "previous version still present:"
    echo "$out"
    return 1
  fi
  return 0
}

echo $CCW277_GATE_PROBE
