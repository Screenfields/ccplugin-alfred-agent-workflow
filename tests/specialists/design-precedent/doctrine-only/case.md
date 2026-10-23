Review the design note below. It serves the work item quoted first. The sources it cites are quoted after it. The brief also carries the passage of the precedent the note names, quoted last.

## Work item (repo Screenfields/ccplugin-alfred-agent-workflow, issue #162)

**Title:** Machine-readable output for `alfred-workitem list`

**Success state:** A script can get the open items from `alfred-workitem` as one JSON array and parse it. `alfred-workitem list` keeps printing what it prints today.

**Acceptance criteria**

1. A JSON form of the listing prints a JSON array with one object per open item, each with `number`, `title` and `state`.
2. `alfred-workitem list` without the JSON form prints exactly the text it prints today.
3. The JSON form prints `[]` when there are no open items.
4. The three behaviours are covered in `tests/workitem.bats`.

**Bounds**

- In scope: the `list` subcommand and the way a script asks for the JSON form.
- Out of scope: other subcommands, a `--format` option, sorting.

## Design note: JSON output for list

Precedent: https://github.com/Screenfields/alfred-platform-docs/blob/main/doctrines/04-prefer-machine-readable-output.md | "Scripts consume what the tools print. Give them an output form that does not need guessing where one field ends and the next begins."

**Problem.** Scripts that read the output of `alfred-workitem list` split it on tabs. `@tsv` writes a tab, a newline or a backslash in a title as `\t`, `\n` or `\\`, and most scripts do not undo that, so those titles come back wrong.

**Current state.** `cmd_list` in `bin/alfred-workitem` already builds the open items as a JSON array of `{number, title, state}` and then prints them as tab-separated text. `list` takes its arguments through `cmd_list "$@"`, and `cmd_list` reads none of them.

**Alternatives.**
- *A. A `--json` flag on `list`.* Pros: the smallest change, since `cmd_list` has the array in hand; one command to document. Cons: `list` then has two output forms behind one name, and every later subcommand that wants JSON needs its own flag.
- *B. A new subcommand `list-json`.* Pros: `list` and its argument handling stay untouched, so the text output cannot regress. Cons: two commands to keep in step, and the fetch code is shared through a helper that does not exist yet.

Recommendation: A, because the array is already built in `cmd_list` and B needs a helper first.

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

> Scripts consume what the tools print. Give them an output form that does not need guessing where one field ends and the next begins.
