Review the design note below. It serves the work item quoted first. The sources it cites are quoted after it. The brief also carries the passage of the precedent the note names, quoted last.

## Work item (repo Screenfields/ccplugin-alfred-agent-workflow, issue #162)

**Title:** Machine-readable output for `alfred-workitem list`

**Success state:** `alfred-workitem list --json` prints the open items as one JSON array that a script can parse. `alfred-workitem list` without the flag prints what it prints today.

**Acceptance criteria**

1. `alfred-workitem list --json` prints a JSON array with one object per open item, each with `number`, `title` and `state`.
2. `alfred-workitem list` without the flag prints exactly the text it prints today.
3. `alfred-workitem list --json` prints `[]` when there are no open items.
4. The three behaviours are covered in `tests/workitem.bats`.

**Bounds**

- In scope: the `list` subcommand.
- Out of scope: other subcommands, a `--format` option, a new subcommand, sorting.

## Design note: JSON output for list

Precedent: https://github.com/Screenfields/ccplugin-alfred-agent-workflow/blob/main/bin/alfred-config | "# names [--json]: print the config keys, as a JSON array with --json"

**Problem.** Scripts that read the output of `alfred-workitem list` split it on tabs. `@tsv` writes a tab, a newline or a backslash in a title as `\t`, `\n` or `\\`, and most scripts do not undo that, so those titles come back wrong.

**Current state.** `cmd_list` in `bin/alfred-workitem` already builds the open items as a JSON array of `{number, title, state}` and then prints them as tab-separated text. `list` takes its arguments through `cmd_list "$@"`, and `cmd_list` reads none of them.

**Alternatives.**
- *Keep the text output and quote tabs inside titles.* Rejected: every script would have to undo the `@tsv` escapes itself, and the array is already built as JSON inside `cmd_list`.
- *A `--format` option.* Rejected: the work item puts a `--format` option out of scope.
- *A new subcommand.* Rejected: the work item puts a new subcommand out of scope.

Only the flag on `list` is viable inside those bounds.

**Design.**
- `cmd_list` tests whether its first argument is `--json`. If it is, it prints `$items` with `jq .` and returns; otherwise the existing `jq -r` line runs unchanged.
- The array is already `{number, title, state}` per item, so no new field is built. When the API returns no open items, `$items` is `[]` and that is what `--json` prints.
- The order is the one the API returns; no sorting is added.
- Three new tests in `tests/workitem.bats` run `cmd_list` with a stubbed `gh` that returns a fixed issues array: `--json` with two items, `--json` with none, and no flag.

**Expected effect.** `bats tests/workitem.bats` shows three more passing tests, and `alfred-workitem list --json | jq length` equals the number of open issues the API returned.

## Source: bin/alfred-workitem (the `list` part, as in the repo now)

```bash
cmd_list() {
  local items
  items=$(gh api "repos/$REPO/issues?state=open&per_page=100" |
    jq 'map({number, title, state})')
  jq -r '.[] | [.number, .state, .title] | @tsv' <<<"$items"
}

case "${1:-}" in
  list) shift; cmd_list "$@" ;;
  show) shift; cmd_show "$@" ;;
  *) usage ;;
esac
```

## Precedent passage carried in the brief

> # names [--json]: print the config keys, as a JSON array with --json
