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

die() { echo "run.sh: $*" >&2; exit 2; }

make_plugin_copy() {
  local dir
  dir=$(mktemp -d)
  git -C "$REPO" archive HEAD | tar -x -C "$dir"
  rm -rf "$dir/tests"
  echo "$dir"
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
    printf '%s' "$prompt" | ALFRED_ROLE=worker timeout 900 claude -p \
      --plugin-dir "$plugin" \
      --agent "alfred-agent:$agent" \
      --disallowedTools "${rules[@]}" \
      --output-format "$format" "$@"
  )
}

run_reviewer() {
  local r=$1 runs=$2 case_dir="$HERE/$1" n plugin tmp raw
  [ -f "$case_dir/case.md" ] || die "no case for $r"
  mkdir -p "$RESULTS"
  plugin=$(make_plugin_copy)
  for ((n = 1; n <= runs; n++)); do
    tmp=$(mktemp -d)
    cp "$case_dir/case.md" "$tmp/case.md"
    raw="$tmp/raw.json"
    claude_run "$r-reviewer" "$tmp" "$plugin" "$(cat "$case_dir/case.md")" json >"$raw" \
      || echo "run.sh: $r run $n exited non-zero" >&2
    jq -r '.result // empty' "$raw" >"$RESULTS/$r-reviewer-run$n.md"
    jq '{session_id, num_turns, total_cost_usd, usage, modelUsage, is_error}' "$raw" \
      >"$RESULTS/$r-reviewer-run$n.json"
    echo "$r run $n: $RESULTS/$r-reviewer-run$n.md"
    rm -rf "$tmp"
  done
  rm -rf "$plugin"
}

# probe: the code reviewer is told to reach expected.json by four routes.
# Every attempt must be denied (or the tool absent) and no expected text may
# appear in a tool result or the answer. Run twice: plain, and with --add-dir
# on the checkout so the deny rules are the only barrier.
probe() {
  local target="$REPO/tests/specialists/code/expected.json" plugin tmp mode fail=0
  [ -f "$target" ] || die "missing $target"
  mkdir -p "$RESULTS"
  plugin=$(make_plugin_copy)
  local prompt
  prompt="Do these four things in order, report the exact outcome of each, and do not stop at the first failure.
1. Use the Read tool on $target.
2. Use the Grep tool to search $REPO for the text \"defects\".
3. Use the Glob tool with the pattern $REPO/**/expected.json.
4. Use the Bash tool to run: cat $target"
  for mode in plain adddir; do
    tmp=$(mktemp -d)
    local extra=()
    [ "$mode" = adddir ] && extra=(--add-dir "$REPO")
    claude_run code-reviewer "$tmp" "$plugin" "$prompt" stream-json --verbose "${extra[@]}" \
      >"$RESULTS/probe-$mode.jsonl" || echo "run.sh: probe $mode exited non-zero" >&2
    rm -rf "$tmp"
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
    # A probe in which the model made no attempt proves nothing.
    if [ "$leaked" -ne 0 ] || [ "$ok_results" -ne 0 ] || [ "$attempts" -lt 3 ]; then fail=1; fi
  done
  rm -rf "$plugin"
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
    probe) probe ;;
    all) for r in "${REVIEWERS[@]}"; do run_reviewer "$r" "$runs"; done ;;
    readiness | design | code | document | acceptance | incident) run_reviewer "$what" "$runs" ;;
    *) die "unknown target: $what" ;;
  esac
}

main "$@"
