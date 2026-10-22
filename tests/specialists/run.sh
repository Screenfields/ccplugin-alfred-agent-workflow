#!/usr/bin/env bash
# Planted-defect runner for the six reviewers (ccplugin#128, AC 2).
#
#   run.sh <readiness|design|code|document|acceptance|incident|all> [--runs N]
#   run.sh probe
#   run.sh deny-rules          print the deny rules the runs use
#
# Live runner, not part of the bats CI job: it calls `claude -p`. It only
# collects outputs; the starting session judges them against expected.json.
#
# Isolation (the answer files must not be reachable):
#   - the plugin is a copy built from `git archive HEAD` without tests/, so
#     expected.json is not under the plugin root;
#   - the run's working directory is a fresh temp dir holding only case.md;
#   - Bash and WebFetch are disallowed, and Read, Grep and Glob are denied on
#     the checkout. The cases are self-contained text, so no Bash is needed;
#   - ALFRED_ROLE=worker makes the routed hook inject the all and worker rules.
# The runner tests HEAD (the plugin copy is built from git archive), not the
# working tree: commit changes to agents/ and skills/ first. It warns when
# they are dirty.
# CLAUDE_BIN overrides the claude binary (the bats tests use a stub).
# Results: tests/specialists/results/<role>-run<N>.md (the answer) and .json
# (usage and session id).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
RESULTS="$HERE/results"
REVIEWERS=(readiness design code document acceptance incident)

# An absolute path in a permission rule needs a double slash: "Read(/$REPO/**)"
# with REPO starting with "/" gives Read(//abs/path/**). A single slash means
# "relative to the project root" and the rule silently fails open.
deny_rules() {
  printf '%s\n' "Bash" "WebFetch" "Read(/$REPO/**)" "Grep(/$REPO/**)" "Glob(/$REPO/**)"
}

CLAUDE_BIN=${CLAUDE_BIN:-claude}
TMPS=()
cleanup() { [ ${#TMPS[@]} -eq 0 ] || rm -rf "${TMPS[@]}"; }
trap cleanup EXIT

die() { echo "run.sh: $*" >&2; exit 2; }

# make_plugin_copy sets PLUGIN_COPY (not a subshell, so the trap sees it).
make_plugin_copy() {
  local dir
  dir=$(mktemp -d)
  TMPS+=("$dir")
  git -C "$REPO" archive HEAD | tar -x -C "$dir"
  rm -rf "$dir/tests"
  PLUGIN_COPY=$dir
}

# claude_run <agent> <cwd> <plugin> <prompt> <format> [extra claude args...]
claude_run() {
  local agent=$1 cwd=$2 plugin=$3 prompt=$4 format=$5
  shift 5
  local rules=()
  mapfile -t rules < <(deny_rules)
  (
    cd "$cwd"
    # The prompt goes on stdin: --add-dir and --disallowedTools are variadic
    # and would swallow a trailing positional prompt.
    printf '%s' "$prompt" | ALFRED_ROLE=worker timeout "${RUN_TIMEOUT:-900}" "$CLAUDE_BIN" -p \
      --plugin-dir "$plugin" \
      --agent "alfred-agent:$agent" \
      --disallowedTools "${rules[@]}" \
      --output-format "$format" "$@"
  )
}

warn_dirty() {
  if [ -n "$(git -C "$REPO" status --porcelain agents/ skills/ 2>/dev/null)" ]; then
    echo "run.sh: WARNING: agents/ or skills/ have uncommitted changes; the runs test HEAD, not the working tree" >&2
  fi
}

# run_reviewer <reviewer> <runs>: returns non-zero when any run failed.
run_reviewer() {
  local r=$1 runs=$2 case_dir="$HERE/$1" n plugin tmp raw rc failed=0
  [ -f "$case_dir/case.md" ] || die "no case for $r"
  mkdir -p "$RESULTS"
  make_plugin_copy
  plugin=$PLUGIN_COPY
  for ((n = 1; n <= runs; n++)); do
    tmp=$(mktemp -d)
    TMPS+=("$tmp")
    cp "$case_dir/case.md" "$tmp/case.md"
    raw="$tmp/raw.json"
    rc=0
    claude_run "$r-reviewer" "$tmp" "$plugin" "$(cat "$case_dir/case.md")" json >"$raw" || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '(.result | length > 0) and (.is_error | not)' "$raw" >/dev/null 2>&1; then
      rm -f "$RESULTS/$r-reviewer-run$n.md" "$RESULTS/$r-reviewer-run$n.json"
      echo "FAILED $r run $n (claude exit $rc)"
      failed=1
      continue
    fi
    jq -r '.result' "$raw" >"$RESULTS/$r-reviewer-run$n.md"
    jq '{session_id, num_turns, total_cost_usd, usage, modelUsage, is_error}' "$raw" \
      >"$RESULTS/$r-reviewer-run$n.json"
    echo "$r run $n: $RESULTS/$r-reviewer-run$n.md"
  done
  return "$failed"
}

# probe: the code reviewer is told to reach expected.json by four routes.
# Every attempt must be denied (or the tool absent) and no expected text may
# appear in a tool result or the answer. Run twice: plain, and with --add-dir
# on the checkout so the deny rules are the only barrier.
probe() {
  local target="$REPO/tests/specialists/code/expected.json" plugin tmp mode fail=0
  [ -f "$target" ] || die "missing $target"
  mkdir -p "$RESULTS"
  make_plugin_copy
  plugin=$PLUGIN_COPY
  local prompt
  prompt="Do these four things in order, report the exact outcome of each, and do not stop at the first failure.
1. Use the Read tool on $target.
2. Use the Grep tool to search $REPO for the text \"defects\".
3. Use the Glob tool with the pattern $REPO/**/expected.json.
4. Use the Bash tool to run: cat $target"
  for mode in plain adddir; do
    tmp=$(mktemp -d)
    TMPS+=("$tmp")
    local extra=()
    [ "$mode" = adddir ] && extra=(--add-dir "$REPO")
    claude_run code-reviewer "$tmp" "$plugin" "$prompt" stream-json --verbose "${extra[@]}" \
      >"$RESULTS/probe-$mode.jsonl" || echo "run.sh: probe $mode exited non-zero" >&2
    jq -r 'select(.type == "result") | .result' "$RESULTS/probe-$mode.jsonl" >"$RESULTS/probe-$mode.md"
    # Each tool attempt and whether its result was an error.
    jq -r '
      (select(.type == "assistant") | .message.content[]? | select(.type == "tool_use")
        | "use \(.id) \(.name) \(.input | tojson)"),
      (select(.type == "user") | .message.content[]? | select(.type == "tool_result")
        | "res \(.tool_use_id) error=\(.is_error // false) \(.content | tostring | .[0:160])")
    ' "$RESULTS/probe-$mode.jsonl" >"$RESULTS/probe-$mode.attempts.txt"
    # A leak is expected text in any tool result or in the answer, or a tool
    # result that is not an error.
    local needles leaked ok_results attempts
    needles=$(jq -r '[.defects[].summary, .sound.summary] | .[]' "$target")
    leaked=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result") | .content | tostring' \
          "$RESULTS/probe-$mode.jsonl" | grep -qF -- "$line"; then leaked=1; fi
      if grep -qF -- "$line" "$RESULTS/probe-$mode.md"; then leaked=1; fi
    done <<<"$needles"
    ok_results=$(jq -r 'select(.type == "user") | .message.content[]? | select(.type == "tool_result")
      | select((.is_error // false) | not) | .tool_use_id' "$RESULTS/probe-$mode.jsonl" | wc -l)
    attempts=$(grep -c '^use ' "$RESULTS/probe-$mode.attempts.txt" || true)
    echo "probe $mode: tool attempts=$attempts, expected text leaked=$leaked, tool results that were not errors=$ok_results"
    cat "$RESULTS/probe-$mode.attempts.txt"
    # The Read, Grep and Glob attempts must each be in the transcript, by
    # name: a probe in which the model skipped a route proves nothing. Bash is
    # absent from the tool list, so it is not attempted.
    for t in Read Grep Glob; do
      if ! grep -q "^use [^ ]* $t " "$RESULTS/probe-$mode.attempts.txt"; then
        echo "probe $mode: no $t attempt in the transcript"
        fail=1
      fi
    done
    if [ "$leaked" -ne 0 ] || [ "$ok_results" -ne 0 ]; then fail=1; fi
  done
  if [ "$fail" -ne 0 ]; then echo "PROBE FAILED: do not start the reviewer runs" >&2; return 1; fi
  echo "PROBE PASSED: every route denied, nothing leaked"
}

main() {
  [ $# -ge 1 ] || die "usage: run.sh <reviewer|all|probe> [--runs N]"
  local what=$1 runs=2
  shift
  while [ $# -gt 0 ]; do
    case $1 in
      --runs) runs=${2:?--runs needs a number}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ $runs =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive number"
  case $what in
    deny-rules) deny_rules ;;
    probe) warn_dirty; probe ;;
    all)
      warn_dirty
      local bad=0
      for r in "${REVIEWERS[@]}"; do run_reviewer "$r" "$runs" || bad=1; done
      return "$bad"
      ;;
    readiness | design | code | document | acceptance | incident) warn_dirty; run_reviewer "$what" "$runs" ;;
    *) die "unknown target: $what" ;;
  esac
}

main "$@"
