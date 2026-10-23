#!/usr/bin/env bash
# Planted-defect runner for the six reviewers (ccplugin#128, AC 2).
#
#   run.sh <readiness|design|code|document|acceptance|incident> [--runs N]
#   run.sh design-precedent [--runs N]   the eight precedent cases (CCW-157)
#   run.sh all [--runs N]                the six reviewers, then design-precedent
#   run.sh check design-precedent [--runs N]
#                              compare the Precedent and Real alternatives lines
#                              of the result files with expected.json; no
#                              network and no claude
#                              (reads indentation, one list marker and **/__ emphasis
#                              loosely; ignores "> " quotes; see normalize_result)
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
# SPECIALISTS_RESULTS overrides the results directory (the bats tests use a
# temp one so they never touch the committed evidence).
# CLAUDE_BIN overrides the claude binary (the bats tests use a stub).
# Results: tests/specialists/results/<role>-run<N>.md (the answer) and .json
# (usage and session id); design-precedent-<case>-run<N>.md and .json for the
# precedent cases.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
RESULTS="${SPECIALISTS_RESULTS:-$HERE/results}"
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
      --permission-mode default \
      --disallowedTools "${rules[@]}" \
      --output-format "$format" "$@"
  )
}

warn_dirty() {
  if [ -n "$(git -C "$REPO" status --porcelain agents/ skills/ 2>/dev/null)" ]; then
    echo "run.sh: WARNING: agents/ or skills/ have uncommitted changes; the runs test HEAD, not the working tree" >&2
  fi
}

# run_case <label> <agent> <case_dir> <stem> <runs> <plugin>: runs one case
# <runs> times. The result files are $RESULTS/<stem>-run<N>.md and .json.
# Returns non-zero when any run failed.
run_case() {
  local label=$1 agent=$2 case_dir=$3 stem=$4 runs=$5 plugin=$6 n tmp raw rc failed=0
  [ -f "$case_dir/case.md" ] || die "no case for $label"
  mkdir -p "$RESULTS"
  for ((n = 1; n <= runs; n++)); do
    tmp=$(mktemp -d)
    TMPS+=("$tmp")
    cp "$case_dir/case.md" "$tmp/case.md"
    # The raw output goes outside the run directory, which holds only case.md.
    raw=$(mktemp)
    TMPS+=("$raw")
    rc=0
    claude_run "$agent" "$tmp" "$plugin" "$(cat "$case_dir/case.md")" json >"$raw" || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '(.result | length > 0) and (.is_error | not)' "$raw" >/dev/null 2>&1; then
      rm -f "$RESULTS/$stem-run$n.md" "$RESULTS/$stem-run$n.json"
      echo "FAILED $label run $n (claude exit $rc)"
      failed=1
      continue
    fi
    jq -r '.result' "$raw" >"$RESULTS/$stem-run$n.md"
    jq '{session_id, num_turns, total_cost_usd, usage, modelUsage, is_error}' "$raw" \
      >"$RESULTS/$stem-run$n.json"
    echo "$label run $n: $RESULTS/$stem-run$n.md"
  done
  return "$failed"
}

# run_reviewer <reviewer> <runs>: returns non-zero when any run failed.
run_reviewer() {
  local r=$1 runs=$2
  [ -f "$HERE/$r/case.md" ] || die "no case for $r"
  make_plugin_copy
  run_case "$r" "$r-reviewer" "$HERE/$r" "$r-reviewer" "$runs" "$PLUGIN_COPY"
}

# run_precedent <runs>: the design-precedent cases in sorted order, one plugin
# copy for all. A failed run does not stop the loop.
run_precedent() {
  local runs=$1 d c failed=0
  make_plugin_copy
  for d in "$HERE"/design-precedent/*/; do
    c=$(basename "$d")
    run_case "design-precedent/$c" design-reviewer "${d%/}" "design-precedent-$c" "$runs" "$PLUGIN_COPY" || failed=1
  done
  return "$failed"
}

# normalize_result <result.md>: the lines of a result as check reads them.
# check is a tolerant reader of presentation only. In this order, per line:
#   1. a line that starts (after leading whitespace) with "> " is a quote of
#      the design note and is dropped;
#   2. leading whitespace is stripped;
#   3. one list marker ("- ", "* " or "N. ") is stripped;
#   4. emphasis around the leading token, **...** or __...__, is stripped
#      (so "**Precedent: invalid** - x" and "**Real alternatives:** yes" read
#      as "Precedent: invalid - x" and "Real alternatives: yes").
# The content is never loosened: the values and the phrase must still match.
normalize_result() {
  sed -E 's/^[[:space:]]+//' "$1" | { grep -v '^>' || true; } |
    sed -E -e 's/^([-*]|[0-9]+\.) +//' \
      -e 's/^\*\*([^*]*)\*\*/\1/' -e 's/^__([^_]*)__/\1/'
}

# check_result <result.md> <expected.json>: the mechanical part of a
# design-precedent comparison. Prints the reason and returns 1 on a mismatch.
# Only the Precedent and Real alternatives lines are read (see
# normalize_result for what is tolerated).
check_result() {
  local f=$1 e=$2 got want norm
  norm=$(normalize_result "$f")
  got=$({ grep -E '^Precedent: |^Real alternatives: ' <<<"$norm" || true; } |
    sed -E 's/^(Precedent|Real alternatives): (valid|invalid|none declared|yes|no).*/\1=\2/' | sort)
  want=$(jq -r '"Precedent=\(.precedent)", (if .alternatives == null then empty else "Real alternatives=\(.alternatives)" end)' "$e" | sort)
  if [ "$got" != "$want" ]; then
    if ! grep -q '^Precedent' <<<"$got"; then
      echo "no Precedent line (expected: $(tr '\n' ';' <<<"$want"))"
    else
      echo "expected: $(tr '\n' ';' <<<"$want") got: $(tr '\n' ';' <<<"$got")"
    fi
    return 1
  fi
  if [ "$(jq -r .source_note "$e")" = true ]; then
    if ! { grep '^Precedent: ' <<<"$norm" || true; } | grep -qF 'passage carried, not read at source'; then
      echo "the Precedent line lacks 'passage carried, not read at source'"
      return 1
    fi
  fi
  return 0
}

# check_precedent <runs>: <runs> is 0 for "the result files that are present"
# (at least one per case), else run1..runN must all be present.
check_precedent() {
  local want_runs=$1 d c f n bad=0 reason nums
  for d in "$HERE"/design-precedent/*/; do
    c=$(basename "$d")
    nums=()
    if [ "$want_runs" -gt 0 ]; then
      for ((n = 1; n <= want_runs; n++)); do nums+=("$n"); done
    else
      for f in "$RESULTS"/design-precedent-"$c"-run*.md; do
        [ -e "$f" ] || continue
        n=${f##*-run}
        nums+=("${n%.md}")
      done
      if [ ${#nums[@]} -eq 0 ]; then
        echo "MISMATCH design-precedent/$c: no result file"
        bad=1
        continue
      fi
    fi
    for n in "${nums[@]}"; do
      f="$RESULTS/design-precedent-$c-run$n.md"
      if [ ! -f "$f" ]; then
        echo "MISMATCH design-precedent/$c run $n: no result file"
        bad=1
      elif reason=$(check_result "$f" "$d/expected.json"); then
        echo "MATCH design-precedent/$c run $n"
      else
        echo "MISMATCH design-precedent/$c run $n: $reason"
        bad=1
      fi
    done
  done
  return "$bad"
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
  [ $# -ge 1 ] || die "usage: run.sh <reviewer|design-precedent|all|probe|check design-precedent> [--runs N]"
  local what=$1 runs="" target=""
  shift
  if [ "$what" = check ]; then
    [ $# -ge 1 ] || die "usage: run.sh check design-precedent [--runs N]"
    target=$1
    shift
  fi
  while [ $# -gt 0 ]; do
    case $1 in
      --runs) runs=${2:?--runs needs a number}; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -z "$runs" ] || [[ $runs =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive number"
  case $what in
    check)
      [ "$target" = design-precedent ] || die "unknown check target: $target"
      check_precedent "${runs:-0}"
      ;;
    deny-rules) deny_rules ;;
    probe) warn_dirty; probe ;;
    all)
      warn_dirty
      local bad=0
      for r in "${REVIEWERS[@]}"; do run_reviewer "$r" "${runs:-2}" || bad=1; done
      run_precedent "${runs:-2}" || bad=1
      return "$bad"
      ;;
    design-precedent) warn_dirty; run_precedent "${runs:-2}" ;;
    readiness | design | code | document | acceptance | incident) warn_dirty; run_reviewer "$what" "${runs:-2}" ;;
    *) die "unknown target: $what" ;;
  esac
}

main "$@"
