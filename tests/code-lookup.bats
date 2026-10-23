#!/usr/bin/env bats
# Behaviour tests for bin/alfred-code-lookup (CCW-122). curl is replaced by
# tests/stub/curl-codes serving the synthetic tests/fixtures/codes-export.json.
# Each case asserts stdout, the exit code and the single stderr line.

setup() {
  LK="$BATS_TEST_DIRNAME/../bin/alfred-code-lookup"
  export STUB_DIR="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$STUB_DIR" "$BATS_TEST_TMPDIR/bin"
  ln -s "$BATS_TEST_DIRNAME/stub/curl-codes" "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PROJECT_MANAGER_URL="http://pm.invalid"
  unset PM_TOKEN_RO
}

mode() { printf '%s' "$1" > "$STUB_DIR/mode"; }

# lookup <input> — stdout in $out, stderr in $err, exit in $rc.
lookup() {
  out=$("$LK" "$1" 2> "$BATS_TEST_TMPDIR/err") && rc=0 || rc=$?
  err=$(cat "$BATS_TEST_TMPDIR/err")
}

# expect <rc> <stdout> <stderr>
expect() {
  [ "$rc" -eq "$1" ] || { echo "rc=$rc want $1 (err: $err)"; return 1; }
  [ "$out" = "$2" ] || { echo "stdout='$out' want '$2'"; return 1; }
  [ "$err" = "$3" ] || { echo "stderr='$err' want '$3'"; return 1; }
}

@test "live code: printed, exit 0, silent" {
  lookup acme/live-repo
  expect 0 LVE ""
}

@test "input is matched case-insensitively" {
  lookup Acme/Live-Repo
  expect 0 LVE ""
}

@test "several live rows: the latest assignedAt wins" {
  lookup acme/multi
  expect 0 MUB ""
}

@test "alias row: the live row with aliasOf is the code" {
  lookup acme/aliased
  expect 0 ALI ""
}

@test "retired code with a live successor: the successor" {
  lookup acme/renamed
  expect 0 REN2 ""
}

@test "two-step chain: follows to the live end" {
  lookup acme/chain
  expect 0 CHA3 ""
}

@test "retired with no successor: exit 1 and the retired line" {
  lookup acme/gone
  expect 1 "" "repo retired; no current code"
}

@test "repo not in the registry: exit 1 and the not-registered line" {
  lookup acme/nothing
  expect 1 "" "no code registered for acme/nothing"
}

@test "input as an https URL" {
  lookup https://github.com/acme/live-repo.git
  expect 0 LVE ""
}

@test "input as an ssh URL" {
  lookup git@github.com:acme/live-repo.git
  expect 0 LVE ""
  lookup ssh://git@github.com/acme/live-repo
  expect 0 LVE ""
}

@test "input as an https URL with an embedded token: code printed, token never echoed" {
  lookup https://x-access-token:ghs_SECRET@github.com/acme/live-repo.git
  expect 0 LVE ""
  lookup https://x-access-token:ghs_SECRET@example.com/acme/live-repo.git
  [ "$rc" -eq 2 ]
  [[ "$err" != *SECRET* ]]
  [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ]
}

@test "no argument: exit 2 and one usage line" {
  run "$LK"
  [ "$status" -eq 2 ]
  [[ "$output" == usage:* ]]
  [ "${#lines[@]}" -eq 1 ]
}

@test "401 without a token: exit 2 and the set PM_TOKEN_RO hint" {
  mode 401
  lookup acme/live-repo
  expect 2 "" "registry refused (HTTP 401); set PM_TOKEN_RO"
}

@test "401 with a token: exit 2 and no hint" {
  mode 401
  export PM_TOKEN_RO=tok-fake
  lookup acme/live-repo
  expect 2 "" "registry refused (HTTP 401)"
}

@test "403 is a refusal too" {
  mode 403
  lookup acme/live-repo
  expect 2 "" "registry refused (HTTP 403); set PM_TOKEN_RO"
}

@test "unreachable registry: exit 2" {
  mode unreachable
  lookup acme/live-repo
  expect 2 "" "registry unreachable (http://pm.invalid/api/codes/export)"
}

@test "5xx: exit 2" {
  mode 5xx
  lookup acme/live-repo
  expect 2 "" "registry error (HTTP 503)"
}

@test "slow registry: the lookup's own 4 s limit stops it, exit 2" {
  mode slow
  start=$SECONDS
  lookup acme/live-repo
  expect 2 "" "registry timed out after 4 s"
  [ $((SECONDS - start)) -lt 8 ]
}

@test "garbage reply: exit 2" {
  mode garbage
  lookup acme/live-repo
  expect 2 "" "registry reply is not valid JSON"
}

@test "JSON without a codes list: exit 2" {
  mode ok
  # a private stub that serves JSON without a codes list
  rm -f "$BATS_TEST_TMPDIR/bin/curl"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
printf '{"version":1}' > "$o"; printf 200
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  lookup acme/live-repo
  expect 2 "" "registry reply has no codes list"
}

@test "call log: bearer header only when PM_TOKEN_RO is set" {
  lookup acme/live-repo
  [ "$(grep -c '^hdr ' "$STUB_DIR/calls.log")" -eq 0 ]
  export PM_TOKEN_RO=tok-fake
  lookup acme/live-repo
  grep -qx 'hdr Authorization: Bearer tok-fake' "$STUB_DIR/calls.log"
}

@test "the token never reaches curl's argv" {
  rm -f "$BATS_TEST_TMPDIR/bin/curl"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_DIR/argv"
while [ $# -gt 0 ]; do case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac; done
printf '{"codes":[]}' > "$o"; printf 200
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PM_TOKEN_RO=tok-fake-argv
  lookup acme/live-repo
  if grep -q tok-fake-argv "$STUB_DIR/argv"; then false; fi
}

@test "PROJECT_MANAGER_URL unset: the fallback registry URL is called" {
  unset PROJECT_MANAGER_URL
  lookup acme/live-repo
  expect 0 LVE ""
  grep -qx 'url https://project-manager.screenfields.net/api/codes/export' "$STUB_DIR/calls.log"
}

@test "PROJECT_MANAGER_URL set: that base is called" {
  lookup acme/live-repo
  grep -qx 'url http://pm.invalid/api/codes/export' "$STUB_DIR/calls.log"
}

@test "init (commands/init.md) calls the lookup with origin and states the left-alone and update cases" {
  f="$BATS_TEST_DIRNAME/../commands/init.md"
  grep -q 'alfred-code-lookup' "$f"
  grep -q 'git remote get-url origin' "$f"
  grep -q 'left alone' "$f"
  grep -q 'updated' "$f"
  grep -q '"code"' "$f"
}
