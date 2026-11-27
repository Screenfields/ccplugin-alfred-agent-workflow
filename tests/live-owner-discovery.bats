#!/usr/bin/env bats
# tests/live/owner-discovery.sh (the CCW-170 live check) on a stub `claude` and
# fake process chains (CCW-245): no model call, no real harness. The stub reads
# the prompt, runs its Step 1 (background) and Step 2 (foreground) as `bash -c`
# under a fake process that is a COPY of bash (its comm is the file name, its
# exe the path; a symlink would resolve to bash), and records what the tests
# compare against: the fake's own pid, the wait's pid and its $PWD.
#
# The live script extracts the bridge's owner rule from bin/alfred-wake, so the
# mutations (AC 4 to 6) run on a copy of the repo made inside $BATS_TEST_TMPDIR.
# Real `claude` ancestors may exist above the fake (a devbox has one), so most
# checks compare against the recorded fake pid F; the exit code is asserted only
# where the chain has no claude ancestor.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
LIVE="$REPO/tests/live/owner-discovery.sh"

setup() {
  REC="$BATS_TEST_TMPDIR/rec"
  mkdir -p "$REC" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/home"
  unset ALFRED_WAKE_OWNER_COMM
  export CLAUDE_CODE_SESSION_ID=sess-245
  export HOME="$BATS_TEST_TMPDIR/home"
  export REC
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  make_stub
}

teardown() {
  local f pid
  for f in fake bg waitpid; do
    pid=$(cat "$REC/$f" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  return 0
}

# make_stub — $BATS_TEST_TMPDIR/bin/claude. A prompt with a Step 1 is the owner
# prompt: exec the fake ($FAKE_BIN) with an inner script that records, starts
# Step 1 in the background and runs Step 2 in the foreground. Any other prompt
# is the session-id one: answer a fixed id.
make_stub() {
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
case "$prompt" in
  *"Step 1:"*) ;;
  *) echo "sess-fixed-245"; exit 0 ;;
esac
S1=$(printf '%s\n' "$prompt" | sed -n '/^Step 1:/{n;p;q}')
S2=$(printf '%s\n' "$prompt" | sed -n '/^Step 2:/{n;p;q}')
export S1 S2
read -r -d '' INNER <<'INNER_END'
printf '%s\n' "$$" > "$REC/fake"
printf '%s\n' "$PWD" > "$REC/pwd"
: > "$REC/chain"
p=$$
while p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $2}'); [ -n "$p" ] && [ "$p" -gt 0 ]; do
  cat "/proc/$p/comm" >> "$REC/chain" 2>/dev/null
done
bash -c "$S1" > /dev/null 2>&1 3>&- &
bg=$!
printf '%s\n' "$bg" > "$REC/bg"
bash -c "$S2"
cp "$PWD/../state/alfred-wake.pid" "$REC/waitpid" 2>/dev/null
wait "$bg"
true
INNER_END
exec "$FAKE_BIN" -c "$INNER"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

# fake <path relative to the test dir> — a copy of bash there; sets FAKE_BIN.
fake() {
  FAKE_BIN="$BATS_TEST_TMPDIR/$1"
  mkdir -p "${FAKE_BIN%/*}"
  cp "$(command -v bash)" "$FAKE_BIN"
  export FAKE_BIN
}

# live <repo dir> — run the live script against it, foreground and bounded.
live() {
  run timeout 100 "$1/tests/live/owner-discovery.sh" "$1" </dev/null
}

# assert_clean — AC 7: the script's temp dir is gone and no recorded process
# (the fake, the background pid, the wait's pid) is alive.
assert_clean() {
  local t f pid
  t=$(dirname "$(cat "$REC/pwd")")
  [ ! -e "$t" ]
  for f in fake bg waitpid; do
    pid=$(cat "$REC/$f" 2>/dev/null || true)
    [ -n "$pid" ]
    ! kill -0 "$pid" 2>/dev/null || false
  done
}

# --- AC 1 and 2: the owner the bridge records is the owner the check finds ---

@test "daemon-form owner: owner, ancestor and status agree on the fake, session id follows" {
  fake claude/versions/2.1.328
  live "$REPO"
  F=$(cat "$REC/fake")
  [[ "$F" =~ ^[0-9]+$ ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"owner=$F ancestor=$F status=0"* ]]
  [[ "$output" == *"session-id=same first=sess-fixed-245 resumed=sess-fixed-245"* ]]
  assert_clean
}

@test "plain claude owner: owner, ancestor and status agree on the fake" {
  fake fake/claude
  live "$REPO"
  F=$(cat "$REC/fake")
  [[ "$F" =~ ^[0-9]+$ ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"owner=$F ancestor=$F status=0"* ]]
  assert_clean
}

# --- AC 3: a version comm with another exe path is not an owner --------------

@test "version comm at another exe path: neither owner nor ancestor is the fake" {
  fake other/2.1.328
  live "$REPO"
  F=$(cat "$REC/fake")
  [[ "$F" =~ ^[0-9]+$ ]]
  [[ "$output" == *"owner="* ]]
  [[ "$output" != *"owner=$F "* ]]
  [[ "$output" != *"ancestor=$F "* ]]
  assert_clean
}

@test "version comm at another exe path, no claude above it: exit 1, no equal pair" {
  fake other/2.1.328
  local out="$BATS_TEST_TMPDIR/iso.out" rc="$BATS_TEST_TMPDIR/iso.rc" i=0
  # Double fork: the script ends up with no claude process above it.
  # (bats runs with errexit, which the subshells inherit: take the code with ||.)
  ( ( r=0; timeout 100 "$LIVE" "$REPO" > "$out" 2>&1 < /dev/null 3>&- || r=$?; echo "$r" > "$rc" ) & ) &
  while [ ! -s "$rc" ] && [ "$i" -lt 1000 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$rc" ] || { cat "$out"; false; }
  # Precondition: nothing above the fake is a claude or a version-form comm.
  if grep -qxE 'claude|[0-9]+\.[0-9]+\.[0-9]+' "$REC/chain"; then
    skip "a claude or version-form process is above the fake: the isolated variant cannot run"
  fi
  [ "$(cat "$rc")" -eq 1 ]
  cat "$out"
  # no pair of equal non-empty numbers
  ! grep -E '^owner=([0-9]+) ancestor=\1 ' "$out" || false
  grep -q '^owner=' "$out"
  assert_clean
}

# --- AC 4 to 6: mutations on a copy of the repo ------------------------------

mutant() {
  MUT="$BATS_TEST_TMPDIR/copy"
  cp -r "$REPO" "$MUT"
}

@test "one home for the rule: widening owner_versioned in bin/alfred-wake changes the verdict" {
  mutant
  cp "$MUT/bin/alfred-wake" "$BATS_TEST_TMPDIR/alfred-wake.orig"
  sed -i 's|\[\[ "\$exe" == \*/claude/versions/"\$2" \]\]|[[ "$exe" == */claude/versions/"$2" \|\| "$exe" == */other/"$2" ]]|' "$MUT/bin/alfred-wake"
  ! cmp -s "$MUT/bin/alfred-wake" "$BATS_TEST_TMPDIR/alfred-wake.orig" || false
  fake other/2.1.328
  live "$MUT"
  F=$(cat "$REC/fake")
  [[ "$F" =~ ^[0-9]+$ ]]
  [ "$status" -eq 0 ]
  [[ "$output" == *"owner=$F ancestor=$F status=0"* ]]
  assert_clean
}

@test "the live script keeps no copy of the owner rule" {
  ! grep -nE 'claude/versions|\[0-9\]\+\\\.' "$LIVE" || false
  ! grep -nE '= claude' "$LIVE" || false
}

@test "a missing bridge piece fails loud: stat_rest" {
  mutant
  sed -i '/^stat_rest() {$/,/^}$/d' "$MUT/bin/alfred-wake"
  live "$MUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"stat_rest"* ]]
  [[ "$output" != *"owner="* ]]
}

@test "a missing bridge piece fails loud: owner_versioned" {
  mutant
  sed -i '/^owner_versioned() {$/,/^}$/d' "$MUT/bin/alfred-wake"
  live "$MUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"owner_versioned"* ]]
  [[ "$output" != *"owner="* ]]
}

@test "a missing bridge piece fails loud: find_owner" {
  mutant
  sed -i '/^find_owner() {$/,/^}$/d' "$MUT/bin/alfred-wake"
  live "$MUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"find_owner"* ]]
  [[ "$output" != *"owner="* ]]
}

@test "a missing bridge piece fails loud: the OWNER_COMM= line" {
  mutant
  sed -i '/^OWNER_COMM=/d' "$MUT/bin/alfred-wake"
  live "$MUT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"OWNER_COMM="* ]]
  [[ "$output" != *"owner="* ]]
}

# --- AC 6: status is part of the verdict -------------------------------------

@test "status is part of the verdict: an owner_check that always says gone fails the check" {
  mutant
  cp "$MUT/bin/alfred-wake" "$BATS_TEST_TMPDIR/alfred-wake.orig"
  sed -i '/^owner_check() {$/,/^}$/ s/^  OWNER_PID=""$/  OWNER_PID=""; OWNER_STATE=gone; return 0/' "$MUT/bin/alfred-wake"
  ! cmp -s "$MUT/bin/alfred-wake" "$BATS_TEST_TMPDIR/alfred-wake.orig" || false
  fake claude/versions/2.1.328
  live "$MUT"
  F=$(cat "$REC/fake")
  [[ "$F" =~ ^[0-9]+$ ]]
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner=$F ancestor=$F status=1"* ]]
  assert_clean
}
