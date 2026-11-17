#!/usr/bin/env bats
# Behaviour tests for bin/alfred-test-run (CCW-218, AP-1499). The tool runs as a child in a
# private PATH dir of symlinks: tests/stub/argv-shim under every external command the tool
# runs (it logs argv and environment, then execs the real binary), and the stubs
# curl-buildkite, age-fake and gh-commit under curl, age and gh. A command the tool uses but
# the dir lacks (cat, awk, dirname) fails the run, which proves it is not used.
# Planted secrets: the origin carries PLANTEDGH, the token file holds ghs_PLANTEDTOKEN, the
# Buildkite token is bkPLANTEDBK0123, and every pipeline fixture hides PLANTEDPIPEENV in its
# env. The common teardown asserts none reaches an argv log, an environment record, output,
# or the HOME, work and TMPDIR directories, and that TMPDIR is empty.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  TR="$ROOT/bin/alfred-test-run"
  FX="$BATS_TEST_DIRNAME/fixtures/test-run"
  STUBS="$BATS_TEST_DIRNAME/stub"
  T="$BATS_TEST_TMPDIR"
  export STUB_DIR="$T/stub" HOME="$T/home" TMPDIR="$T/tmp"
  WORK="$T/work"; PBIN="$T/bin"
  mkdir -p "$STUB_DIR" "$HOME" "$TMPDIR" "$WORK" "$PBIN"
  export ARGV_LOG="$STUB_DIR/shim.log" SHIM_REAL_PATH="$PATH" SHIM_FAKE_SLEEP=1
  : > "$STUB_DIR/calls.log"
  BKT=bkPLANTEDBK0123
  NOW=1800000000
  export BUILDKITE_API_TOKEN="$BKT" BUILDKITE_ORGANIZATION_SLUG=acme
  export ALFRED_TEST_RUN_TOKEN_FILE="$STUB_DIR/token" ALFRED_TEST_RUN_RECIPIENTS="$STUB_DIR/recipients.txt"
  export ALFRED_TEST_RUN_NOW="$NOW" ALFRED_TEST_RUN_POLL=1 ALFRED_TEST_RUN_BACKOFF=0
  unset BUILDKITE_API_URL
  printf 'ghs_PLANTEDTOKEN\n' > "$STUB_DIR/token.real"
  ln -s "$STUB_DIR/token.real" "$STUB_DIR/token"
  age_ago 60
  cp "$FX/recipients.txt" "$STUB_DIR/recipients.txt"
  cp "$FX/pipeline-ok.json" "$STUB_DIR/pipeline.json"
  cp "$FX/create.json" "$STUB_DIR/create.json"
  cp "$FX/build-passed.json" "$STUB_DIR/build.1.json"
  build_path ""
  git -C "$WORK" init -q -b main
  git -C "$WORK" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$WORK" remote add origin 'https://x-access-token:PLANTEDGH@github.com/Screenfields/motion.git'
  HEAD_SHA=$(git -C "$WORK" rev-parse HEAD)
  export GIT_CEILING_DIRECTORIES="$T"
  cd "$WORK" || return 1
}

teardown() {
  local f pat='PLANTEDTOKEN|bkPLANTEDBK|PLANTEDGH|PLANTEDPIPEENV'
  chmod 700 "$TMPDIR" 2>/dev/null
  for f in shim.log argv.log age.argv gh.argv; do
    if [ -f "$STUB_DIR/$f" ] && grep -qE "$pat" "$STUB_DIR/$f"; then echo "secret in argv log $f" >&3; return 1; fi
  done
  for f in shim.log.env env.log age.env gh.env; do
    if [ -f "$STUB_DIR/$f" ] && grep -qF "$BKT" "$STUB_DIR/$f"; then echo "Buildkite token in env record $f" >&3; return 1; fi
  done
  if [ -f "$T/all.out" ] && grep -qE "$pat" "$T/all.out"; then echo "secret in output" >&3; return 1; fi
  if [ -n "$(ls -A "$TMPDIR")" ]; then echo "TMPDIR not empty: $(ls -A "$TMPDIR")" >&3; return 1; fi
  if grep -rE --exclude-dir=.git "$pat" "$HOME" "$WORK" "$TMPDIR" >/dev/null 2>&1; then echo "secret on disk" >&3; return 1; fi
  return 0
}

# --- helpers -----------------------------------------------------------------
# build_path <omitted command>: the private PATH dir
build_path() {
  local c
  rm -f "$PBIN"/*
  for c in jq git sed tr head tail grep stat date mktemp rm sleep timeout; do
    [ "$c" = "$1" ] || ln -s "$STUBS/argv-shim" "$PBIN/$c"
  done
  [ "$1" = curl ] || ln -s "$STUBS/curl-buildkite" "$PBIN/curl"
  [ "$1" = age ] || ln -s "$STUBS/age-fake" "$PBIN/age"
  [ "$1" = gh ] || ln -s "$STUBS/gh-commit" "$PBIN/gh"
}
age_ago() { touch -d "@$((NOW - $1))" "$STUB_DIR/token.real"; }
go() {
  run --separate-stderr env PATH="$PBIN" "$BASH" "$TR" "$@"
  printf '%s\n%s\n' "$output" "$stderr" >> "$T/all.out"
}
reset_calls() { : > "$STUB_DIR/calls.log"; rm -f "$STUB_DIR"/count.* "$STUB_DIR/calls.n" "$STUB_DIR/age.argv" "$STUB_DIR/age.plain"; }
ncalls() { grep -c "$1" "$STUB_DIR/calls.log"; }
posts() { grep -c '^POST ' "$STUB_DIR/calls.log"; }
# errlines: the stderr lines other than the test-seam warning
errlines() { printf '%s\n' "$stderr" | grep -v 'test seam active' | grep -v '^$'; }
one_err() { [ "$(errlines | wc -l)" -eq 1 ]; }
# fails <status> [args]: exit status, one stderr line, nothing sent
fails() {
  local want=$1; shift
  go "$@"
  [ "$status" -eq "$want" ]
  one_err
  [ ! -s "$STUB_DIR/calls.log" ]
}
setbuild() { cp "$FX/build-$2.json" "$STUB_DIR/build.$1.json"; }
envelope() { jq -c . "$STUB_DIR/age.plain"; }
set_origin() { git remote set-url origin "$1"; }
logfx() { cp "$FX/log-120-lines.json" "$STUB_DIR/log-11111111-1111-1111-1111-111111111111.json"; }
last_is_build() { [ "$(printf '%s\n' "$output" | tail -1)" = "build: https://buildkite.com/acme/motion-tests/builds/42" ]; }

# =============================================================================
# AC 1: fail closed, each missing input
@test "AC1: BUILDKITE_API_TOKEN unset" {
  unset BUILDKITE_API_TOKEN
  fails 2
  [[ "$stderr" == *BUILDKITE_API_TOKEN* ]]
}
@test "AC1: BUILDKITE_ORGANIZATION_SLUG unset" {
  unset BUILDKITE_ORGANIZATION_SLUG
  fails 2
  [[ "$stderr" == *BUILDKITE_ORGANIZATION_SLUG* ]]
}
@test "AC1: token file absent" { rm -f "$STUB_DIR/token"; fails 3; [[ "$stderr" == *"token file"* ]]; }
@test "AC1: token file empty" { : > "$STUB_DIR/token.real"; fails 3; [[ "$stderr" == *"token file"* ]]; }
@test "AC1: recipients file absent" { rm -f "$STUB_DIR/recipients.txt"; fails 2; [[ "$stderr" == *recipients* ]]; }
@test "AC1: recipients file with only comments" {
  printf '# nothing\n\n' > "$STUB_DIR/recipients.txt"; fails 2; [[ "$stderr" == *recipients* ]]
}
@test "AC1: recipients file with no age1 line" {
  printf 'garbage\n' > "$STUB_DIR/recipients.txt"; fails 2; [[ "$stderr" == *recipients* ]]
}
@test "AC1: recipients file with an ssh-ed25519 line next to a valid one" {
  printf 'ssh-ed25519 AAAAC3Nza\nage1qyqszqgpqyqszqgp\n' > "$STUB_DIR/recipients.txt"; fails 2; [[ "$stderr" == *recipients* ]]
}
@test "AC1: each required tool missing from PATH" {
  local t
  for t in age jq curl git gh timeout; do
    build_path "$t"; reset_calls
    fails 2
    [[ "$stderr" == *"$t"* ]]
  done
}
@test "AC1: missing age gives the install hint" {
  build_path age
  fails 2
  [ "$(errlines)" = "alfred-test-run: age not found; install it with /workspace/.devbox/init.sh (pinned version and checksum)" ]
}
@test "AC1: not in a git repository" {
  mkdir "$T/nogit"; cd "$T/nogit"
  fails 2
  [[ "$stderr" == *"git repository"* ]]
}
@test "AC1: no origin remote" { git remote remove origin; fails 2; [[ "$stderr" == *origin* ]]; }

# AC 2: commit
@test "AC2: a short, a 41-character and an uppercase commit are refused" {
  fails 2 --commit abc1234
  fails 2 --commit "${HEAD_SHA}0"
  fails 2 --commit "$(printf '%s' "$HEAD_SHA" | tr 'a-f' 'A-F' | tr '0-9' 'A')"
}
@test "AC2: the default commit is git rev-parse HEAD and gh is asked about it" {
  go
  [ "$status" -eq 0 ]
  grep -qx "api repos/Screenfields/motion/commits/$HEAD_SHA --jq .sha" "$STUB_DIR/gh.argv"
  [ "$(envelope | jq -r .commit)" = "$HEAD_SHA" ]
}
@test "AC2: a commit gh answers 404 for is not pushed" {
  echo notfound > "$STUB_DIR/gh-mode"
  fails 2
  [[ "$stderr" == *"not pushed or no access"* ]]
  [[ "$stderr" == *"${HEAD_SHA:0:12}"* ]]
}
@test "AC2: a gh answer with another sha is not pushed" {
  echo wrongsha > "$STUB_DIR/gh-mode"
  fails 2
  [[ "$stderr" == *"not pushed or no access"* ]]
}

# AC 3: slug and origin
@test "AC3: every origin form gives owner Screenfields and repo motion" {
  local u
  for u in 'https://x-access-token:PLANTEDGH@github.com/Screenfields/motion.git' \
           'https://github.com/Screenfields/motion' \
           'git@github.com:Screenfields/motion.git' \
           'ssh://git@github.com/Screenfields/motion.git'; do
    set_origin "$u"; reset_calls
    go
    [ "$status" -eq 0 ]
    grep -q '^POST .*/pipelines/motion-tests/builds$' "$STUB_DIR/calls.log"
    [ "$(envelope | jq -r .repo)" = "$(jq -r .repository "$STUB_DIR/pipeline.json")" ]
  done
}
@test "AC3: a repo My_Repo gives the slug my-repo-tests" {
  set_origin 'https://github.com/Screenfields/My_Repo.git'
  jq '.repository = "https://github.com/Screenfields/My_Repo.git"' "$FX/pipeline-ok.json" > "$STUB_DIR/pipeline.json"
  go
  [ "$status" -eq 0 ]
  grep -q '^POST .*/pipelines/my-repo-tests/builds$' "$STUB_DIR/calls.log"
}
@test "AC3: --pipeline replaces the slug and a bad slug is refused" {
  go --pipeline x-y
  [ "$status" -eq 0 ]
  grep -q '^POST .*/pipelines/x-y/builds$' "$STUB_DIR/calls.log"
  reset_calls
  fails 2 --pipeline 'X y'
}
@test "AC3: origins that cannot be parsed are refused without echoing them" {
  local u
  for u in 'https://x-access-token:PLANTEDGH@github.com/' 'PLANTEDGH@@host'; do
    set_origin "$u"
    fails 2
  done
}
@test "AC3: an origin on another host is refused" {
  set_origin 'https://gitlab.com/Screenfields/motion.git'
  fails 2
  [[ "$stderr" == *github.com* ]]
}

# AC 4: token age
@test "AC4: ages 1199 and 1200 s proceed" {
  age_ago 1199; go; [ "$status" -eq 0 ]
  age_ago 1200; reset_calls; go; [ "$status" -eq 0 ]
}
@test "AC4: age 1201 s is stale, exit 3, nothing sent" {
  age_ago 1201
  fails 3
  [[ "$stderr" == *"1201 s"* ]]
  [[ "$stderr" == *"39 min"* ]]
  [[ "$stderr" == *stale* ]]
  [ ! -e "$STUB_DIR/age.argv" ]
}
@test "AC4: not_after is mtime+3600 s in RFC 3339 UTC (age 0 and age 900)" {
  age_ago 0
  go; [ "$status" -eq 0 ]
  [ "$(envelope | jq -r .not_after)" = "$(date -u -d "@$((NOW + 3600))" +%Y-%m-%dT%H:%M:%SZ)" ]
  age_ago 900; reset_calls
  go; [ "$status" -eq 0 ]
  [ "$(envelope | jq -r .not_after)" = "$(date -u -d "@$((NOW + 2700))" +%Y-%m-%dT%H:%M:%SZ)" ]
  [[ "$(envelope | jq -r .not_after)" == *Z ]]
}
@test "AC4: a modification time in the future is refused" {
  touch -d "@$((NOW + 100))" "$STUB_DIR/token.real"
  fails 3
}
@test "AC4: the symlink target's mtime decides (stat -L)" {
  touch -h -d "@$((NOW - 5000))" "$STUB_DIR/token"
  age_ago 10
  go
  [ "$status" -eq 0 ]
}

# AC 5: envelope
@test "AC5: age gets exactly -a -R <recipients> and the schema v1 plaintext" {
  go
  [ "$status" -eq 0 ]
  [ "$(cat "$STUB_DIR/age.argv")" = "-a -R $STUB_DIR/recipients.txt" ]
  [ "$(envelope | jq -c 'keys')" = '["commit","not_after","pipeline","repo","token","v"]' ]
  [ "$(envelope | jq -r .v)" = 1 ]
  [ "$(envelope | jq -r .token)" = ghs_PLANTEDTOKEN ]
  [ "$(envelope | jq -r .pipeline)" = motion-tests ]
}
@test "AC5: the token has no trailing newline when the file has none either" {
  printf 'ghs_PLANTEDTOKEN' > "$STUB_DIR/token.real"; age_ago 60
  go
  [ "$status" -eq 0 ]
  [ "$(envelope | jq -r .token)" = ghs_PLANTEDTOKEN ]
}
@test "AC5: a real age round trip" {
  command -v age >/dev/null && command -v age-keygen >/dev/null || skip "age is not installed (CI installs it)"
  age-keygen -o "$T/key.txt" 2>/dev/null
  age-keygen -y "$T/key.txt" > "$STUB_DIR/recipients.txt"
  rm -f "$PBIN/age"
  ln -s "$(command -v age)" "$PBIN/age"
  go
  [ "$status" -eq 0 ]
  jq -r '.env.ALFRED_GIT_ENVELOPE' "$STUB_DIR/body.2" | age -d -i "$T/key.txt" > "$T/plain.json"
  [ "$(jq -r .token "$T/plain.json")" = ghs_PLANTEDTOKEN ]
  [ "$(jq -r .commit "$T/plain.json")" = "$HEAD_SHA" ]
  [ "$(jq -r .repo "$T/plain.json")" = "https://github.com/Screenfields/motion.git" ]
  rm -f "$T/plain.json" "$T/key.txt"
}
