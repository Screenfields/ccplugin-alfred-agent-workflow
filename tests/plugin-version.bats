#!/usr/bin/env bats
# CCW-223: the previous plugin version (main's) must not linger under tests/ or
# .claude-plugin/. No version is typed here: it comes from origin/main.

load helpers/plugin-version

ROOT="$BATS_TEST_DIRNAME/.."

# mk_repo <prev|-> <cur>: temp repo whose origin/main carries <prev> ("-" means
# origin/main has no plugin.json) and whose working tree carries <cur>.
mk_repo() {
  R="$BATS_TEST_TMPDIR/repo"
  rm -rf "$R"; mkdir -p "$R/tests" "$R/.claude-plugin"
  git -C "$R" init -q
  git -C "$R" config user.email t@example.invalid
  git -C "$R" config user.name t
  echo seed > "$R/tests/seed.txt"
  if [ "$1" != - ]; then
    jq -n --arg v "$1" '{name:"x",version:$v}' > "$R/.claude-plugin/plugin.json"
  fi
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  jq -n --arg v "$2" '{name:"x",version:$v}' > "$R/.claude-plugin/plugin.json"
}

# check_pv <root>: sets rc and out without tripping bats' errexit.
check_pv() {
  rc=0
  out=$(previous_version_leftovers "$1") || rc=$?
}

@test "real repo: the check passes or skips, never fails" {
  rc=0
  out=$(previous_version_leftovers "$ROOT") || rc=$?
  [ "$rc" -ne 1 ] || { echo "$out" >&3; return 1; }
  if [ "$rc" -eq 3 ]; then skip "$out"; fi
}

@test "real repo: plugin.json version has the N.N.N shape" {
  [[ "$(plugin_version "$ROOT")" =~ $PV_SHAPE ]]
}

@test "leftover previous version under tests/ fails and names the file" {
  mk_repo 7.0.0 7.1.0
  echo "pin 7.0.0" > "$R/tests/stale.txt"
  check_pv "$R"
  [ "$rc" -eq 1 ]
  [[ "$out" == *tests/stale.txt* ]]
}

@test "leftover previous version under .claude-plugin/ fails" {
  mk_repo 7.0.0 7.1.0
  echo "old 7.0.0" > "$R/.claude-plugin/other.txt"
  check_pv "$R"
  [ "$rc" -eq 1 ]
  [[ "$out" == *.claude-plugin/other.txt* ]]
}

@test "bumped version with a clean tree passes" {
  mk_repo 7.0.0 7.1.0
  check_pv "$R"
  [ "$rc" -eq 0 ]
}

@test "equal versions skip with a reason" {
  mk_repo 7.0.0 7.0.0
  check_pv "$R"
  [ "$rc" -eq 3 ]
  [ "$out" = "version not bumped here" ]
}

@test "origin/main missing: skip locally, fail with CI=true" {
  mk_repo 7.0.0 7.1.0
  git -C "$R" update-ref -d refs/remotes/origin/main
  unset CI
  check_pv "$R"
  [ "$rc" -eq 3 ]
  [[ "$out" == *"no origin/main"* ]]
  CI=true check_pv "$R"
  [ "$rc" -eq 1 ]
}

@test "origin/main without plugin.json: skip locally, fail with CI=true" {
  mk_repo - 7.1.0
  unset CI
  check_pv "$R"
  [ "$rc" -eq 3 ]
  [ "$out" = "no previous version on origin/main" ]
  CI=true check_pv "$R"
  [ "$rc" -eq 1 ]
}

@test "origin/main version null: skip locally, fail with CI=true" {
  mk_repo 7.0.0 7.1.0
  echo '{"name":"x","version":null}' > "$R/.claude-plugin/plugin.json"
  git -C "$R" commit -q -am nullver
  git -C "$R" update-ref refs/remotes/origin/main HEAD
  echo '{"name":"x","version":"7.1.0"}' > "$R/.claude-plugin/plugin.json"
  unset CI
  check_pv "$R"
  [ "$rc" -eq 3 ]
  [ "$out" = "no previous version on origin/main" ]
  CI=true check_pv "$R"
  [ "$rc" -eq 1 ]
}

@test "origin/main version not N.N.N: skip locally, fail with CI=true" {
  mk_repo 7.5 7.1.0
  unset CI
  check_pv "$R"
  [ "$rc" -eq 3 ]
  [ "$out" = "no previous version on origin/main" ]
  CI=true check_pv "$R"
  [ "$rc" -eq 1 ]
}

@test "malformed working-tree version fails the shape test" {
  mk_repo 7.0.0 7.5
  ! [[ "$(plugin_version "$R")" =~ $PV_SHAPE ]]
}
