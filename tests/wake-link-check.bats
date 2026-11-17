#!/usr/bin/env bats
# CCW-220: hooks/wake-link-check.sh refreshes a stale installed alfred-wake.
# The hook derives its plugin dir from $0, so the real hook and bridge are
# copied into a temp "new" plugin. No test touches the real ~/.local/bin.

REPO="$BATS_TEST_DIRNAME/.."

setup() {
  NEW="$BATS_TEST_TMPDIR/new"
  OLD="$BATS_TEST_TMPDIR/old"
  BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  SHIMS="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$NEW/hooks" "$NEW/bin" "$OLD/bin" "$SHIMS" "$PROJ/.alfred"
  cp "$REPO/hooks/wake-link-check.sh" "$NEW/hooks/"
  cp "$REPO/bin/alfred-wake" "$NEW/bin/"
  echo '{"agent_id":"test-lead"}' >"$PROJ/.alfred/config.json"
  PLUGIN="$NEW"
  NEW_VER=$(sed -n 's/^VERSION="\([0-9][0-9.]*\)"$/\1/p' "$NEW/bin/alfred-wake")
  OLD_VER=1.0.0
  export ALFRED_WAKE_BIN_DIR="$BIN"
  unset ALFRED_WAKE_LINK_CHECK
}

# hook [source]: run the hook with a SessionStart payload; stdout only.
hook() {
  local src="${1-startup}"
  if [ "$src" = none ]; then
    printf '{"cwd":"%s"}' "$PROJ" | "$NEW/hooks/wake-link-check.sh" 2>/dev/null
  else
    printf '{"cwd":"%s","source":"%s"}' "$PROJ" "$src" | "$NEW/hooks/wake-link-check.sh" 2>/dev/null
  fi
}

# mkver FILE VERSION: a copy of the bridge with another VERSION.
mkver() {
  sed "s/^VERSION=\"[0-9.]*\"/VERSION=\"$2\"/" "$REPO/bin/alfred-wake" >"$1"
  chmod +x "$1"
}

stale_link() {
  mkver "$OLD/bin/alfred-wake" "$OLD_VER"
  mkdir -p "$BIN"
  ln -s "$OLD/bin/alfred-wake" "$BIN/alfred-wake"
}

stale_copy() {
  mkdir -p "$BIN"
  mkver "$BIN/alfred-wake" "$OLD_VER"
  touch -d '2020-01-01 00:00:00' "$BIN/alfred-wake"
}

# ln shims, first on PATH.
shim_copy() {
  cat >"$SHIMS/ln" <<'SH'
#!/bin/bash
rm -f "$3"
cp "$2" "$3"
SH
  chmod +x "$SHIMS/ln"
  PATH="$SHIMS:$PATH"
}
shim_fail() {
  printf '#!/bin/bash\nexit 1\n' >"$SHIMS/ln"
  chmod +x "$SHIMS/ln"
  PATH="$SHIMS:$PATH"
}
shim_remove_fail() {
  printf '#!/bin/bash\nrm -f "$3"\nexit 1\n' >"$SHIMS/ln"
  chmod +x "$SHIMS/ln"
  PATH="$SHIMS:$PATH"
}
shim_sleep() {
  printf '#!/bin/bash\nexec sleep 30 3>&-\n' >"$SHIMS/ln"
  chmod +x "$SHIMS/ln"
  PATH="$SHIMS:$PATH"
}

st() { stat -c '%i %Y' "$1"; }

# one_line_json OLD: the AC 5 checks on $output.
one_line_json() {
  [ "$(printf '%s' "$output" | jq -s length)" = 1 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("\n") | not' >/dev/null
  printf '%s' "$output" | jq -e --arg o "$1" --arg n "$NEW_VER" \
    '.hookSpecificOutput.additionalContext | (contains("install") and contains($o) and contains($n))' >/dev/null
}

@test "CCW-220 AC1: a symlink into an older cache dir is repointed" {
  stale_link
  run hook
  [ "$status" -eq 0 ]
  [ "$(readlink -f "$BIN/alfred-wake")" = "$(readlink -f "$PLUGIN/bin/alfred-wake")" ]
  [ -z "$output" ]
}

@test "CCW-220 AC2: a stale regular file is replaced by a copy" {
  stale_copy
  shim_copy
  run hook
  [ "$status" -eq 0 ]
  cmp -s "$BIN/alfred-wake" "$PLUGIN/bin/alfred-wake"
  [ -z "$output" ]
}

@test "CCW-220 AC3: an already current symlink is untouched and silent" {
  mkdir -p "$BIN"
  ln -s "$PLUGIN/bin/alfred-wake" "$BIN/alfred-wake"
  touch -h -d '2020-01-01 00:00:00' "$BIN/alfred-wake"
  before=$(st "$BIN/alfred-wake")
  run hook
  [ "$status" -eq 0 ]
  [ "$(st "$BIN/alfred-wake")" = "$before" ]
  [ -z "$output" ]
}

@test "CCW-220 AC3: an identical copy is untouched and silent" {
  mkdir -p "$BIN"
  cp "$PLUGIN/bin/alfred-wake" "$BIN/alfred-wake"
  touch -d '2020-01-01 00:00:00' "$BIN/alfred-wake"
  before=$(st "$BIN/alfred-wake")
  run hook
  [ "$status" -eq 0 ]
  [ "$(st "$BIN/alfred-wake")" = "$before" ]
  [ -z "$output" ]
}

@test "CCW-220 AC4a: no bin dir is not created" {
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$BIN" ]
}

@test "CCW-220 AC4b: a bin dir without alfred-wake gets nothing" {
  mkdir -p "$BIN"
  echo x >"$BIN/other"
  before=$(ls -A "$BIN")
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ls -A "$BIN")" = "$before" ]
}

@test "CCW-220 AC4c: alfred-wake as a directory is left alone" {
  mkdir -p "$BIN/alfred-wake"
  touch -d '2020-01-01 00:00:00' "$BIN/alfred-wake"
  before=$(ls -A "$BIN"; st "$BIN/alfred-wake")
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ls -A "$BIN"; st "$BIN/alfred-wake")" = "$before" ]
  [ -d "$BIN/alfred-wake" ] && [ ! -L "$BIN/alfred-wake" ]
}

@test "CCW-220 AC4d: a dangling symlink is repaired" {
  mkdir -p "$BIN"
  ln -s "$BATS_TEST_TMPDIR/gone/alfred-wake" "$BIN/alfred-wake"
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink -f "$BIN/alfred-wake")" = "$(readlink -f "$PLUGIN/bin/alfred-wake")" ]
}

@test "CCW-220 AC4e: a symlink to a directory is left alone" {
  mkdir -p "$BIN" "$BATS_TEST_TMPDIR/somedir"
  touch "$BATS_TEST_TMPDIR/somedir/f"
  touch -d '2020-01-01 00:00:00' "$BATS_TEST_TMPDIR/somedir"
  ln -s "$BATS_TEST_TMPDIR/somedir" "$BIN/alfred-wake"
  before=$(ls -A "$BATS_TEST_TMPDIR/somedir"; st "$BATS_TEST_TMPDIR/somedir")
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink "$BIN/alfred-wake")" = "$BATS_TEST_TMPDIR/somedir" ]
  [ "$(ls -A "$BATS_TEST_TMPDIR/somedir"; st "$BATS_TEST_TMPDIR/somedir")" = "$before" ]
}

@test "CCW-220 AC5: a failed refresh prints one JSON line of context" {
  stale_link
  shim_fail
  run hook
  [ "$status" -eq 0 ]
  one_line_json "$OLD_VER"
}

@test "CCW-220 AC5: a refresh that removes the link reports missing" {
  stale_link
  shim_remove_fail
  run hook
  [ "$status" -eq 0 ]
  [ ! -e "$BIN/alfred-wake" ] && [ ! -L "$BIN/alfred-wake" ]
  one_line_json missing
}

@test "CCW-220 AC6: no agent_id leaves the link alone" {
  stale_link
  rm -f "$PROJ/.alfred/config.json"
  run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink "$BIN/alfred-wake")" = "$OLD/bin/alfred-wake" ]
}

@test "CCW-220 AC6: ALFRED_WAKE_LINK_CHECK=0 leaves the link alone" {
  stale_link
  ALFRED_WAKE_LINK_CHECK=0 run hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink "$BIN/alfred-wake")" = "$OLD/bin/alfred-wake" ]
}

@test "CCW-220 AC7: hooks.json registers the hook in its own group" {
  run jq -e '.hooks.SessionStart[] | select(any(.hooks[]; .command | test("wake-link-check.sh"))) | (.matcher == "startup|resume") and (.hooks | length == 1) and (.hooks[0].timeout | type == "number" and . <= 5)' "$REPO/hooks/hooks.json"
  [ "$status" -eq 0 ]
}
