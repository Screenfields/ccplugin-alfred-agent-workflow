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
  for c in jq git sed tr head tail grep stat date mktemp rm rmdir sleep timeout; do
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
    grep -q "^$c " "$STUB_DIR/shim.log" || { echo "no shim record for $c: $output / $stderr" >&3; return 1; }
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

# AC 11: API errors and retries
@test "AC11: create answers 401, 403, 404 or 422: exit 4, code and message, one call" {
  local c
  for c in 401 403 404 422; do
    reset_calls; echo "$c" > "$STUB_DIR/fail-create"
    go
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"HTTP $c: stubbed $c"* ]]
    [ "$(posts)" -eq 1 ]
    [[ "$stderr" != *"may exist"* ]]
  done
}
@test "AC11: create answers 429 once then 201" {
  echo '429 1' > "$STUB_DIR/fail-create"
  go
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 2 ]
}
@test "AC11: create answers 429 every time: 4 POSTs, exit 4, no may exist" {
  echo '429' > "$STUB_DIR/fail-create"
  go
  [ "$status" -eq 4 ]
  [ "$(posts)" -eq 4 ]
  [[ "$stderr" != *"may exist"* ]]
}
@test "AC11: create ends in curl exit 7 once, then 201" {
  echo 'curl-exit 7 1' > "$STUB_DIR/fail-create"
  go
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 2 ]
}
@test "AC11: an unknown create outcome is exit 4 with one POST and the may-exist message" {
  local m
  for m in 'curl-exit 28' 'curl-exit 56' 'curl-exit 52' '500' '302'; do
    reset_calls; echo "$m" > "$STUB_DIR/fail-create"
    go
    [ "$status" -eq 4 ]
    [ "$(posts)" -eq 1 ]
    [[ "$stderr" == *"the build may exist: check the pipeline for this commit"* ]]
  done
  rm -f "$STUB_DIR/fail-create"
  echo 'not json' > "$STUB_DIR/body-create"; reset_calls
  go; [ "$status" -eq 4 ]; [ "$(posts)" -eq 1 ]; [[ "$stderr" == *"may exist"* ]]
  rm -f "$STUB_DIR/body-create"; cp "$FX/create-no-number.json" "$STUB_DIR/create.json"; reset_calls
  go; [ "$status" -eq 4 ]; [ "$(posts)" -eq 1 ]; [[ "$stderr" == *"may exist"* ]]
  last_is_build
}
@test "AC11: the may-exist message never prints an http or control-character web_url" {
  echo '{"web_url":"http://evil.test/x"}' > "$STUB_DIR/body-create"
  go
  [ "$status" -eq 4 ]
  ! printf '%s\n%s' "$output" "$stderr" | grep -q 'evil.test'
  printf '{"web_url":"https://buildkite.com/x\\u0007y"}' > "$STUB_DIR/body-create"
  go
  [ "$status" -eq 4 ]
  [[ "$output" != *build:* ]]
}
@test "AC11: the pipeline GET answers 403 or 404: exit 4 with the code, no create" {
  local c
  for c in 403 404; do
    reset_calls; echo "$c" > "$STUB_DIR/fail-pipeline"
    go
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"HTTP $c"* ]]
    [ "$(posts)" -eq 0 ]
  done
}
@test "AC11: the pipeline GET answers 500 every time: 4 GETs, no create" {
  echo 500 > "$STUB_DIR/fail-pipeline"
  go
  [ "$status" -eq 4 ]
  [ "$(ncalls '^GET ')" -eq 4 ]
  [ "$(posts)" -eq 0 ]
}
@test "AC11: build GETs answering 500 or 429 every time: 4 GETs, exit 4, ends with the build line" {
  local c
  for c in 500 429; do
    reset_calls; echo "$c" > "$STUB_DIR/fail-build"
    go
    [ "$status" -eq 4 ]
    [ "$(ncalls '/builds/42$')" -eq 4 ]
    last_is_build
  done
}
@test "AC11: curl exits 6, 7 and 28 on a build GET fail twice then succeed" {
  local c
  for c in 6 7 28; do
    reset_calls; echo "curl-exit $c 2" > "$STUB_DIR/fail-build"
    go
    [ "$status" -eq 0 ]
    [ "$(ncalls '/builds/42$')" -eq 3 ]
  done
}
@test "AC11: Retry-After and RateLimit-Reset set the wait, capped at 30" {
  echo '429 1' > "$STUB_DIR/fail-build"
  printf 'Retry-After: 2\n' > "$STUB_DIR/headers-build"
  go; [ "$status" -eq 0 ]; grep -qx 'sleep 2' "$STUB_DIR/shim.log"
  printf 'RateLimit-Reset: 2\n' > "$STUB_DIR/headers-build"; : > "$STUB_DIR/shim.log"; reset_calls
  go; [ "$status" -eq 0 ]; grep -qx 'sleep 2' "$STUB_DIR/shim.log"
  printf 'Retry-After: 99\n' > "$STUB_DIR/headers-build"; : > "$STUB_DIR/shim.log"; reset_calls
  go; [ "$status" -eq 0 ]; grep -qx 'sleep 30' "$STUB_DIR/shim.log"
}

# AC 12: calls
@test "AC12: every curl call has the timeouts and --proto =https, none follows redirects" {
  setbuild 1 job-failed; logfx
  go
  [ "$status" -eq 10 ]
  [ "$(sed -n 1p "$STUB_DIR/calls.log")" = "GET https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests" ]
  [ "$(wc -l < "$STUB_DIR/argv.log")" -eq 4 ]
  while IFS= read -r line; do
    [[ "$line" == *"--connect-timeout 10"* ]]
    [[ "$line" == *"--proto =https"* ]]
    [[ "$line" != *" -L "* && "$line" != *"--location"* ]]
    [[ "$line" =~ --max-time\ ([0-9]+) ]]
    [ "${BASH_REMATCH[1]}" -le 30 ]
  done < "$STUB_DIR/argv.log"
  [ "$(posts)" -eq 1 ]
  ! grep -qi cancel "$STUB_DIR/calls.log"
}

# AC 13: static (shellcheck itself runs in CI and in the brief's command)
@test "AC13: the script parses and is executable" {
  bash -n "$TR"
  [ -x "$TR" ]
}

# AC 16: envelope pipe failures
@test "AC16: a jq failure in the envelope pipe is exit 4, no create" {
  export SHIM_FAIL=jq SHIM_FAIL_ARG=not_after
  go
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"envelope encryption failed"* ]]
  [ "$(posts)" -eq 0 ]
}
@test "AC16: age failing, bad header, no END line: exit 4, no create" {
  local m
  for m in fail bad-header no-end no-begin; do
    echo "$m" > "$STUB_DIR/age-mode"; reset_calls
    go
    [ "$status" -eq 4 ]
    [ "$(posts)" -eq 0 ]
  done
}
@test "AC16: age echoing the plaintext is exit 4, with and without a trailing newline in the token file" {
  echo echo-plain > "$STUB_DIR/age-mode"
  go; [ "$status" -eq 4 ]; [ "$(posts)" -eq 0 ]
  printf 'ghs_PLANTEDTOKEN' > "$STUB_DIR/token.real"; age_ago 60; reset_calls
  go; [ "$status" -eq 4 ]; [ "$(posts)" -eq 0 ]
}

# AC 17: values from responses and the API base
@test "AC17: a create number of 12;x or ../x is exit 4 and no GET of a build" {
  local f
  for f in create-bad-number create-dot-number; do
    cp "$FX/$f.json" "$STUB_DIR/create.json"; reset_calls
    go
    [ "$status" -eq 4 ]
    [[ "$stderr" == *"may exist"* ]]
    [ "$(ncalls '^GET .*/builds')" -eq 0 ]
  done
}
@test "AC17: a failed job id of ../../x gets no log request" {
  cp "$FX/build-bad-job-id.json" "$STUB_DIR/build.1.json"
  go
  [ "$status" -eq 10 ]
  printf '%s\n' "$output" | grep -qx 'log unavailable'
  [ "$(ncalls '/log$')" -eq 0 ]
}
@test "AC17: an http API base is refused unless the loopback seam allows it" {
  BUILDKITE_API_URL=http://x fails 2
  export ALFRED_TEST_RUN_ALLOW_HTTP=1
  BUILDKITE_API_URL=http://evil.test fails 2
  export BUILDKITE_API_URL=http://127.0.0.1:1
  go
  [ "$status" -eq 0 ]
  grep -q '^GET http://127.0.0.1:1/v2/' "$STUB_DIR/calls.log"
  export BUILDKITE_API_URL=http://localhost:1
  reset_calls
  go
  [ "$status" -eq 0 ]
  grep -q '^GET http://localhost:1/v2/' "$STUB_DIR/calls.log"
}

# AC 18: log unavailable
@test "AC18: a log GET answering 500 every time: 4 GETs, log unavailable, exit 10" {
  setbuild 1 job-failed
  echo 500 > "$STUB_DIR/fail-log"
  go
  [ "$status" -eq 10 ]
  [ "$(ncalls '/log$')" -eq 4 ]
  printf '%s\n' "$output" | grep -qx 'log unavailable'
  printf '%s\n' "$output" | grep -qx 'job passed lint'
}

# AC 20: URL and config injection
@test "AC20: a bad organization slug is exit 2 with nothing sent" {
  local s
  for s in 'A b' 'x/../y' '-x' $'ab\ncd'; do
    BUILDKITE_ORGANIZATION_SLUG="$s" fails 2
  done
}
@test "AC20: a Buildkite token with a space, a quote or a newline is exit 2" {
  local s
  for s in 'bk PLANTEDBK' 'bk"PLANTEDBK' $'bk\nPLANTEDBK'; do
    BUILDKITE_API_TOKEN="$s" fails 2
  done
}
@test "AC20: a trailing slash on the base gives no // and userinfo is refused" {
  BUILDKITE_API_URL=https://api.example/ go
  [ "$status" -eq 0 ]
  grep -q '^GET https://api.example/v2/' "$STUB_DIR/calls.log"
  ! grep -q 'example//v2' "$STUB_DIR/calls.log"
  reset_calls
  BUILDKITE_API_URL=https://user:pw@api.example fails 2
  [[ "$stderr" != *pw* && "$stderr" != *user* ]]
}
@test "AC20: a 302 on the pipeline GET, create, build GET or log GET is not followed" {
  local k
  printf 'Location: http://evil.test/x\n' > "$STUB_DIR/headers-pipeline"
  for k in create build log; do cp "$STUB_DIR/headers-pipeline" "$STUB_DIR/headers-$k"; done
  for k in pipeline create build; do
    reset_calls; rm -f "$STUB_DIR"/fail-*; echo 302 > "$STUB_DIR/fail-$k"
    go
    [ "$status" -eq 4 ]
    case $k in
      pipeline) [ "$(ncalls '^GET ')" -eq 1 ] ;;
      create) [ "$(posts)" -eq 1 ] ;;
      build) [ "$(ncalls '/builds/42$')" -eq 1 ] ;;
    esac
    ! grep -q evil.test "$STUB_DIR/calls.log"
  done
  # a log GET: "log unavailable" and exit 10 (AC 18 and the Change section), one call
  rm -f "$STUB_DIR"/fail-*; echo 302 > "$STUB_DIR/fail-log"; setbuild 1 job-failed; reset_calls
  go
  [ "$status" -eq 10 ]
  [ "$(ncalls '/log$')" -eq 1 ]
  ! grep -q evil.test "$STUB_DIR/calls.log"
}
@test "AC20: web_url, url and jobs[].url that point elsewhere are never fetched or printed" {
  cp "$FX/pipeline-evil.json" "$STUB_DIR/pipeline.json"
  cp "$FX/create-evil.json" "$STUB_DIR/create.json"
  setbuild 1 running; setbuild 2 job-failed
  go
  [ "$status" -eq 10 ]
  ! grep -q evil.test "$STUB_DIR/calls.log"
  [[ "$output" != *evil.test* ]]
  [ "$(printf '%s\n' "$output" | head -1)" = 'build: acme/motion-tests #42' ]
}

# AC 21: temp dir and residue (the residue greps run in every teardown)
@test "AC21: a failing mktemp is exit 4 with no curl call" {
  export SHIM_FAIL=mktemp
  go
  [ "$status" -eq 4 ]
  [ ! -s "$STUB_DIR/calls.log" ]
}
@test "AC21: an unwritable TMPDIR is exit 4 with no curl call" {
  [ "$(id -u)" -ne 0 ] || skip "root can write anywhere"
  chmod 500 "$TMPDIR"
  go
  [ "$status" -eq 4 ]
  [ ! -s "$STUB_DIR/calls.log" ]
  chmod 700 "$TMPDIR"
}

# AC 22: bound
@test "AC22: every build GET hangs: the run ends within 3 + 3 + 5 s with each max-time within the time left" {
  echo hang > "$STUB_DIR/fail-build"
  unset SHIM_FAKE_SLEEP
  export ALFRED_TEST_RUN_MIN_WAIT=1 ALFRED_TEST_RUN_REPORT_CAP=3
  local t0=$SECONDS m
  go --wait-timeout 3
  [ "$status" -eq 11 ]
  [ $((SECONDS - t0)) -le 11 ]
  last_is_build
  for m in $(grep '^build ' "$STUB_DIR/maxtime.log" | cut -d' ' -f2); do [ "$m" -le 3 ] && [ "$m" -ge 1 ]; done
}
@test "AC22: six failed jobs give at most five log GETs and one 'more failed jobs not shown'" {
  setbuild 1 six-failed
  go
  [ "$status" -eq 10 ]
  [ "$(ncalls '/log$')" -le 5 ]
  [ "$(printf '%s\n' "$output" | grep -c '^more failed jobs not shown$')" -eq 1 ]
}
@test "AC22: with the report cap used up the remaining jobs get log unavailable" {
  setbuild 1 six-failed
  echo hang > "$STUB_DIR/fail-log"
  unset SHIM_FAKE_SLEEP
  export ALFRED_TEST_RUN_REPORT_CAP=2
  go
  [ "$status" -eq 10 ]
  [ "$(ncalls '/log$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^log unavailable$')" -eq 5 ]
}

# AC 23: seams
@test "AC23: one warning line naming the single seam that is set" {
  local v
  for v in TOKEN_FILE RECIPIENTS NOW BACKOFF REPORT_CAP MIN_WAIT ALLOW_HTTP; do unset "ALFRED_TEST_RUN_$v"; done
  go
  [ "$(printf '%s\n' "$stderr" | grep -c '^alfred-test-run: warning: test seam active:')" -eq 1 ]
  printf '%s\n' "$stderr" | grep -q '^alfred-test-run: warning: test seam active: ALFRED_TEST_RUN_POLL$'
  unset ALFRED_TEST_RUN_POLL
  go
  [[ "$stderr" != *"test seam active"* ]]
}

# AC 24: pipeline repository
@test "AC24: a pipeline repository that is not the origin's https .git URL is refused" {
  local v val
  for v in ssh http userinfo nogit otherhost missing other case; do
    cp "$FX/pipeline-$v.json" "$STUB_DIR/pipeline.json"; reset_calls
    go
    [ "$status" -eq 2 ]
    one_err
    [ "$(posts)" -eq 0 ]
    [ ! -e "$STUB_DIR/age.argv" ]
    val=$(jq -r '.repository // empty' "$STUB_DIR/pipeline.json")
    [ -z "$val" ] || [[ "$stderr" != *"$val"* ]]
  done
}
@test "AC24: a repo name with dot, underscore and dash is accepted" {
  set_origin 'https://github.com/Screenfields/a.b_c-d.git'
  cp "$FX/pipeline-abcd.json" "$STUB_DIR/pipeline.json"
  go --pipeline abcd-tests
  [ "$status" -eq 0 ]
  [ "$(envelope | jq -r .repo)" = "https://github.com/Screenfields/a.b_c-d.git" ]
}

# AC 14: docs
@test "AC14: README has the test run section with each required item" {
  local s
  for s in 'Test run (`bin/alfred-test-run`)' \
    'alfred-test-run [--pipeline <slug>] [--commit <40-hex>] [--branch <name>] [--wait-timeout <seconds>]' \
    '| Code | Meaning |' 'timeout $((wait + 300))' 'timeout 2100' 'exit notification' \
    'After exit 11 or 4, open the build URL; do not hand-poll.' 'PR 1500' '`age`' \
    '/workspace/.devbox/init.sh' 'https://api.buildkite.com' 'BUILDKITE_API_URL' \
    'The create request is not retried on a timeout or a 5xx' \
    'Start a new run; do not use rebuild. The worker refuses a rebuild.' \
    'write_builds' 'read_builds' 'read_build_logs' 'read_pipelines' '.repository'; do
    grep -qF -- "$s" "$ROOT/README.md" || { echo "README lacks: $s" >&3; return 1; }
  done
}

# review round 1
@test "AC7: an exported internal name does not reach a child environment" {
  export BK_TOKEN=callerx TOKVAL=callery
  go
  [ "$status" -eq 0 ]
  ! grep -E 'declare -x (BK_TOKEN|TOKVAL)=' "$STUB_DIR/shim.log.env" "$STUB_DIR/env.log" "$STUB_DIR/age.env" "$STUB_DIR/gh.env"
}
@test "AC1: --wait-timeout 08 is read as decimal" {
  export ALFRED_TEST_RUN_MIN_WAIT=1
  go --wait-timeout 08
  [ "$status" -eq 0 ]
}

# =============================================================================
# CCW-249: --print-lines <text>
# plog <1|2|3|...> <fixture>: serve a log fixture for the job with the uuid of that digit
plog() { local d=$1; cp "$FX/$2" "$STUB_DIR/log-${d}${d}${d}${d}${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}-${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}${d}.json"; }
BUILD42='build: https://buildkite.com/acme/motion-tests/builds/42'

@test "PL1: passed build prints the matched lines, scrubbed, prefixed, in the job frame" {
  plog 1 log-e2e-summary.json; plog 2 log-no-marker.json
  go --print-lines 'e2e summary:'
  [ "$status" -eq 0 ]
  local want
  want="$BUILD42
job passed unit
job passed lint
unit: e2e summary: refused=3 total=40
unit: e2e summary: crlf
unit: e2e summary: leaks [redacted] and [redacted]
lint: print-lines: no match
state: passed
$BUILD42"
  [ "$output" = "$want" ]
  ! printf '%s' "$output" | grep -q 'bk;t='
  ! printf '%s' "$output" | grep -q $'\033'
  ! printf '%s' "$output" | grep -q $'\r'
  [[ "$stderr" != *ghs_LOGPLANTED* ]]
  [[ "$stderr" != *bkPLANTEDBK* ]]
  local l
  while IFS= read -r l; do
    [[ "$l" =~ ^GET\ https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests$ ]] \
      || [[ "$l" =~ ^POST\ https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests/builds$ ]] \
      || [[ "$l" =~ ^GET\ https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests/builds/42$ ]] \
      || [[ "$l" =~ ^GET\ https://api.buildkite.com/v2/organizations/acme/pipelines/motion-tests/builds/42/jobs/[0-9a-f-]{36}/log$ ]] \
      || { echo "unexpected call: $l" >&3; return 1; }
  done < "$STUB_DIR/calls.log"
  [ "$(ncalls '/log$')" -eq 2 ]
  while IFS= read -r l; do
    [[ "$l" == *"--connect-timeout 10"* ]] && [[ "$l" == *"--proto =https"* ]] || { echo "argv: $l" >&3; return 1; }
    [[ "$l" != *" -L "* ]]
    [[ "$l" =~ --max-time\ ([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -le 30 ]
  done < "$STUB_DIR/argv.log"
}

@test "PL7: a bad --print-lines value is exit 2 with the named message, before any call" {
  local v
  for v in '' $'a\nb' $'a\tb' $'a\033[0m'; do
    reset_calls
    go --print-lines "$v"
    [ "$status" -eq 2 ]
    one_err
    [ ! -s "$STUB_DIR/calls.log" ]
    [[ "$(errlines)" != *[[:cntrl:]]* ]]
    [[ "$stderr" != *"unknown argument"* ]]
    [[ "$(errlines)" == *"--print-lines needs a non-empty single-line value"* ]]
  done
  reset_calls
  go --print-lines
  [ "$status" -eq 2 ]
  one_err
  [ ! -s "$STUB_DIR/calls.log" ]
  [[ "$stderr" != *"unknown argument"* ]]
  [[ "$(errlines)" == *"--print-lines needs a value"* ]]
}
