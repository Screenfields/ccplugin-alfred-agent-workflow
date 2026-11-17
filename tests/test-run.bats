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

# AC 6: create call
@test "AC6: one POST with commit, branch and exactly the envelope env" {
  go
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 1 ]
  grep -q '^POST https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests/builds$' "$STUB_DIR/calls.log"
  local body="$STUB_DIR/body.2"
  [ "$(jq -r .commit "$body")" = "$HEAD_SHA" ]
  [ "$(jq -r .branch "$body")" = main ]
  [ "$(jq -c '.env | keys' "$body")" = '["ALFRED_GIT_ENVELOPE"]' ]
  [[ "$(jq -r .env.ALFRED_GIT_ENVELOPE "$body")" == "-----BEGIN AGE ENCRYPTED FILE-----"* ]]
  ! grep -q 'PLANTEDTOKEN' "$body"
}
@test "AC6: the -K config holds the headers, mode 600, in a 700 directory with only 600 files" {
  go
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer' "$STUB_DIR/cfg.1"
  grep -q 'Content-Type: application/json' "$STUB_DIR/cfg.1"
  [ "$(sort -u "$STUB_DIR/cfgmode.log")" = 600 ]
  [ "$(sort -u "$STUB_DIR/cfgdirmode.log")" = 700 ]
  [ "$(sort -u "$STUB_DIR/dirfiles.log")" = 600 ]
  [ "$(sort -u "$STUB_DIR/bodymode.log")" = 600 ]
}
@test "AC6: --branch overrides and a detached HEAD without it is refused" {
  go --branch feature/x
  [ "$status" -eq 0 ]
  [ "$(jq -r .branch "$STUB_DIR/body.2")" = feature/x ]
  reset_calls
  git checkout -q --detach
  fails 2
  [[ "$stderr" == *"detached"* ]]
}

# AC 7: secrets, mechanical (the argv, environment, output and disk checks run in every teardown)
@test "AC7: every external command the tool runs goes through the argv shim" {
  setbuild 1 running; setbuild 2 job-failed; logfx
  go
  [ "$status" -eq 10 ]
  local c
  for c in jq git sed tr stat date mktemp rm sleep timeout tail grep; do
    grep -q "^$c " "$STUB_DIR/shim.log" || { echo "no shim record for $c" >&3; return 1; }
  done
}
@test "AC7: the temp dir is empty after success and after failure" {
  go; [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
  echo '{"message":"no"}' > "$STUB_DIR/body-create"; echo 422 > "$STUB_DIR/fail-create"
  go; [ "$status" -eq 4 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
@test "AC7: static greps over the script" {
  ! grep -nE 'set +-[a-z]*x' "$TR"
  ! grep -n '<<' "$TR"
  # an assignment to a variable named TOKEN, KEY or SECRET followed by a command on the same line
  ! grep -nE '(^|[;&|(]|then|do)[[:space:]]*[A-Za-z_]*(TOKEN|KEY|SECRET)[A-Za-z_]*=[^[:space:]]*[[:space:]]+[A-Za-z_./$"]' "$TR"
}

# AC 8: wait and report, pass
@test "AC8: creating, running, passed prints build, jobs, state, build" {
  setbuild 1 creating; setbuild 2 running; setbuild 3 passed
  go
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "build: https://buildkite.com/acme/motion-tests/builds/42" ]
  last_is_build
  printf '%s\n' "$output" | grep -qx 'job passed unit'
  printf '%s\n' "$output" | grep -qx 'job passed lint'
  [ "$(printf '%s\n' "$output" | grep -c '^job ')" -eq 2 ]
  printf '%s\n' "$output" | grep -qx 'state: passed'
  [ "$(sed -n 1p "$STUB_DIR/calls.log")" = "GET https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests" ]
  [ "$(sed -n 2p "$STUB_DIR/calls.log")" = "POST https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests/builds" ]
  [ "$(ncalls '/builds/42$')" -eq 3 ]
  [ "$(ncalls '/log$')" -eq 0 ]
}

# AC 9: failed job, states, untrusted text
@test "AC9: failed, timed_out and broken jobs print exactly 50 clean log lines" {
  local s
  logfx
  for s in failed timed_out broken; do
    setbuild 1 "job-$s"; reset_calls
    go
    [ "$status" -eq 10 ]
    [ "$(printf '%s\n' "$output" | grep -c 'LOGLINE-')" -eq 50 ]
    printf '%s\n' "$output" | grep -q 'LOGLINE-120'
    ! printf '%s\n' "$output" | grep -q 'LOGLINE-070'
    printf '%s\n' "$output" | grep -qx "job $s unit"
    printf '%s\n' "$output" | grep -qx 'job passed lint'
    printf '%s\n' "$output" | grep -qx 'state: failed'
    ! printf '%s' "$output" | grep -q $'\033'
    ! printf '%s' "$output" | grep -q $'\r'
    ! printf '%s' "$output" | grep -q 'bk;t='
    ! printf '%s' "$output" | grep -q 'progress 10%'
    printf '%s\n' "$output" | grep -q 'leaks \[redacted\] and \[redacted\]'
    [ "$(ncalls '/log$')" -eq 1 ]
  done
}
@test "AC9: blocked, skipped, not_run, canceled and passed-with-blocked end with exit 10 and their state" {
  local s want
  for s in blocked skipped not_run canceled passed-blocked; do
    cp "$FX/build-$s.json" "$STUB_DIR/build.1.json"
    want=$s; [ "$s" = passed-blocked ] && want=blocked
    go
    [ "$status" -eq 10 ]
    printf '%s\n' "$output" | grep -qx "state: $want"
  done
}
@test "AC9: failing, canceling, scheduled and waiting keep polling until passed" {
  local s
  for s in failing canceling scheduled waiting; do
    setbuild 1 "$s"; setbuild 2 passed; reset_calls
    go
    [ "$status" -eq 0 ]
    [ "$(ncalls '/builds/42$')" -ge 2 ]
  done
}
@test "AC9: an unknown state is exit 4" {
  setbuild 1 weird
  go
  [ "$status" -eq 4 ]
  [[ "$stderr" == *unknown* ]]
}
@test "AC9: a job name with escapes and a newline is cleaned" {
  cp "$FX/build-odd-name.json" "$STUB_DIR/build.1.json"
  logfx
  go
  [ "$status" -eq 10 ]
  ! printf '%s' "$output" | grep -q $'\033'
  [ "$(printf '%s\n' "$output" | grep -c '^job failed red')" -eq 1 ]
}
@test "AC9: a 500 character API message with control characters is cut to 300 and cleaned" {
  printf '{"message":"%s\\u0007\\u001b[31m%s"}' "$(printf 'x%.0s' $(seq 1 250))" "$(printf 'y%.0s' $(seq 1 250))" > "$STUB_DIR/body-create"
  echo 422 > "$STUB_DIR/fail-create"
  go
  [ "$status" -eq 4 ]
  ! printf '%s' "$stderr" | grep -q $'[\001-\010\013-\037]'
  [ "$(printf '%s' "$stderr" | tr -cd 'xy' | wc -c)" -le 300 ]
  [[ "$stderr" == *"HTTP 422"* ]]
}
@test "AC9: a secret in the pipeline env never appears (success and failure)" {
  go; [ "$status" -eq 0 ]
  echo 403 > "$STUB_DIR/fail-pipeline"; reset_calls
  go; [ "$status" -eq 4 ]
}

# AC 10: bound and signals
@test "AC10: a build that stays running ends with exit 11 within 4 s and is not cancelled" {
  setbuild 1 running
  unset SHIM_FAKE_SLEEP
  export ALFRED_TEST_RUN_MIN_WAIT=1
  local t0=$SECONDS
  go --wait-timeout 2
  [ "$status" -eq 11 ]
  [ $((SECONDS - t0)) -le 4 ]
  [[ "$stderr" == *"still running"* ]]
  last_is_build
  ! grep -qi cancel "$STUB_DIR/calls.log"
}
@test "AC10: --wait-timeout below 30 is refused unless the seam lowers it" {
  fails 2 --wait-timeout 29
  [[ "$stderr" == *"at least 30"* ]]
}
# sig_run <signal> <exit code> [build marker]: start in the background, signal, check
sig_run() {
  setbuild 1 running
  unset SHIM_FAKE_SLEEP
  export ALFRED_TEST_RUN_POLL=30
  [ -z "${3:-}" ] || echo "$3" > "$STUB_DIR/fail-build"
  set -m
  env PATH="$PBIN" "$BASH" "$TR" > "$T/sig.out" 2> "$T/sig.err" &
  local pid=$! i
  for i in $(seq 1 100); do
    [ "$(grep -c '/builds/42$' "$STUB_DIR/calls.log")" -ge 1 ] && break
    sleep 0.1
  done
  local t0=$SECONDS
  kill "-$1" "$pid"
  local rc=0; wait "$pid" || rc=$?
  set +m
  printf '%s\n%s\n' "$(cat "$T/sig.out")" "$(cat "$T/sig.err")" >> "$T/all.out"
  [ "$rc" -eq "$2" ]
  [ $((SECONDS - t0)) -le 2 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}
@test "AC10: TERM while sleeping gives 143, the URL already printed, TMPDIR empty" {
  sig_run TERM 143
  grep -q '^build: https://buildkite.com' "$T/sig.out"
}
@test "AC10: INT gives 130" { sig_run INT 130; grep -q '^build:' "$T/sig.out"; }
@test "AC10: HUP gives 129" { sig_run HUP 129; grep -q '^build:' "$T/sig.out"; }
@test "AC10: TERM while a build GET hangs gives 143" { sig_run TERM 143 hang; }
