Review the document below. It is a README section in a public repository. The source it describes is quoted after it.

## Document: README.md, section "Parking with `alfred-park`"

`bin/alfred-park` writes a resume note on every open work item that is in progress, so the next session can pick up where this one stopped. Run it when you park.

```
alfred-park [--repo OWNER/NAME] [--all] [--dry-run] [--label NAME]
```

- **`--repo OWNER/NAME`** is the repository to read. Without it the script uses the repository of the current directory.
- **`--label NAME`** selects the items. The default is `status:ready`.
- **`--all`** writes a note on every open item, whatever its label.
- **`--dry-run`** prints `would comment on #N` for each item instead of commenting. It still needs `gh` authentication and network access, because it reads the issue list; only the comments are skipped.

The script reads at most 50 items per run. It exits 0 when every note was written, 1 when no open item matched, and 2 on a usage error.

Typical use from the lead's devbox (`devbox-alfred-cc-tools-0`, node `pve-03`, internal address `10.20.4.31`), before the pod is stopped:

```
alfred-park --repo Screenfields/ccplugin-alfred-agent-workflow --dry-run
alfred-park --repo Screenfields/ccplugin-alfred-agent-workflow
```

## Source: bin/alfred-park

```bash
#!/usr/bin/env bash
# alfred-park — write a resume note on every open item of this repo.
#
#   alfred-park [--repo OWNER/NAME] [--dry-run] [--label NAME]
#
# Exit 0 when every note was written (or nothing matched), 1 when a comment
# failed, 2 on a usage error or when the repo cannot be determined.
set -u

repo=""
dry=0
label="status:in-progress"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || exit 2; repo="$2"; shift 2 ;;
    --label) [ $# -ge 2 ] || exit 2; label="$2"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "usage: alfred-park [--repo OWNER/NAME] [--dry-run] [--label NAME]" >&2; exit 2 ;;
  esac
done

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || exit 2
fi

items=$(gh issue list --repo "$repo" --label "$label" --state open --limit 50 \
  --json number -q '.[].number') || exit 2

rc=0
for n in $items; do
  note="Resume note ($(TZ=Europe/Amsterdam date +%Y-%m-%dT%H:%M%z)): parked by the lead; state is in this item and its branch."
  if [ "$dry" -eq 1 ]; then
    echo "would comment on #$n"
  else
    gh issue comment "$n" --repo "$repo" --body "$note" >/dev/null || rc=1
  fi
done
exit "$rc"
```
