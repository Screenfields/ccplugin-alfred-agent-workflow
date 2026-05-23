---
name: release
description: >
  Automate marketplace plugin pin-bumps for the alfred-cc-tools catalog. Takes a plugin name
  and new version, verifies the upstream source PR is merged, bumps the version pin in
  marketplace.json, commits on a branch, opens a PR, and merges when CI is green.
  Use when bumping a plugin version pin: "release alfred-agent 1.9.8",
  "bump alfred-content to 1.1.0", "release new version of alfred-platform-ops".
allowed-tools: Bash, Read, Edit
---

# alfred-agent:release

Orchestrates the 6-step marketplace pin-bump flow for a single invocation.
Invoke as: `/alfred-agent:release {plugin-name} {new-version}`

Parameters:
- `plugin-name` — one of: `alfred-agent`, `alfred-content`, `alfred-platform-ops`
- `new-version` — target version string (e.g., `1.9.8`)

> **Note on `platform-gh`:** The issue spec mentioned `platform-gh` as a possible wrapper for `gh`. No such binary or alias exists in this repository or the alfred-cc-tools constellation — the standard `gh` CLI is used throughout. If `platform-gh` is introduced to the platform in future, replace `gh` with `platform-gh` in the commands below.

---

## Plugin registry

Before any step, resolve `plugin-name` to its source repo:

| plugin-name | source repo | marketplace entry name |
|-------------|-------------|------------------------|
| `alfred-agent` | `Screenfields/ccplugin-alfred-agent-workflow` | `alfred-agent` |
| `alfred-content` | `Screenfields/ccplugin-alfred-content` | `alfred-content` |
| `alfred-platform-ops` | `Screenfields/ccplugin-alfred-platform-ops` | `alfred-platform-ops` |

If `plugin-name` does not match any row, stop immediately:

```
ERROR: unknown plugin-name "{plugin-name}".
Valid values: alfred-agent, alfred-content, alfred-platform-ops
```

---

## Step 1 — Verify upstream PR is merged

Confirm that the upstream plugin source repo has a PR that introduced `new-version` and that it is merged. Do NOT proceed if the work has not landed in the source repo.

```bash
# List merged PRs from the source repo — look for a PR whose title or body references new-version
gh pr list --repo {source-repo} --state merged --limit 20 --json number,title,mergedAt \
  | python3 -c "import sys,json; prs=json.load(sys.stdin); [print(f'#{p[\"number\"]} ({p[\"mergedAt\"][:10]}): {p[\"title\"]}') for p in prs]"
```

**Evaluation:**
- If a PR whose title or body references `new-version` is found and its `mergedAt` is non-null → assertion passes. Note the PR number.
- If no matching PR is found → warn and require explicit user confirmation before proceeding:

```
WARNING: No merged PR referencing {new-version} found in {source-repo}.
The upstream change may not have landed yet, or the PR title may not reference the version.

Merged PRs (most recent 20):
{output above}

Confirm: should I proceed with the pin-bump anyway? (yes / no)
```

Stop and wait for user confirmation. If the user says no, stop. If yes, note the override and continue.

---

## Step 2 — Verify release tag exists (if applicable)

Check whether the source repo has a release tag for `new-version`. Tags are not required for all plugins, but their absence may indicate a bump is premature.

```bash
gh release list --repo {source-repo} --limit 10 2>/dev/null \
  || gh api repos/{source-repo}/tags --jq '.[].name' 2>/dev/null \
  | head -10
```

**Evaluation:**
- If a release or tag matching `new-version` (exact match or prefixed with `v`) is found → note it and proceed.
- If no matching release/tag is found → warn (do NOT hard-stop; tags are advisory):

```
WARNING: No release or tag found for {new-version} in {source-repo}.
If the upstream workflow creates tags on merge, wait for the tag before bumping.
Proceeding anyway — confirm this is expected.
```

If this warning triggers, pause and ask the user to confirm before continuing.

---

## Step 3 — Read current pin from marketplace.json

Clone `Screenfields/alfred-cc-tools` to a temp directory and read the current version pin.

```bash
CATALOG_DIR=$(mktemp -d)
gh repo clone Screenfields/alfred-cc-tools "$CATALOG_DIR"
cd "$CATALOG_DIR"
git config user.email "alfred-cc-tools@screenfields.net"
git config user.name "alfred-cc-tools-devbox"
```

Read the current version:

```bash
python3 -c "
import json
with open('.claude-plugin/marketplace.json') as f:
    data = json.load(f)
for p in data['plugins']:
    if p['name'] == '{plugin-name}':
        print(p.get('version', '(none)'))
        break
else:
    print('NOT_FOUND')
"
```

**Evaluation:**
- If output is `NOT_FOUND` → the plugin is not yet in the catalog. This is a new catalog addition, not a bump. Follow the catalog-addition path in Step 4b.
- Otherwise → record `old-version` and proceed to Step 4a.

If `old-version == new-version`, stop:

```
ERROR: marketplace.json already pins {plugin-name} at {new-version}. Nothing to do.
```

---

## Step 4a — Bump the version pin (existing plugin)

Create a branch and update the `version` field:

```bash
cd "$CATALOG_DIR"
BRANCH="{plugin-name}/bump-{new-version}"
git checkout -b "$BRANCH"
```

Edit `.claude-plugin/marketplace.json` — change the `version` field of the matching plugin entry from `old-version` to `new-version`. Use Read + Edit tools (preferred) or a targeted `python3` rewrite:

```bash
python3 - <<'PYEOF'
import json, re

with open('.claude-plugin/marketplace.json') as f:
    raw = f.read()

data = json.loads(raw)
for p in data['plugins']:
    if p['name'] == '{plugin-name}':
        p['version'] = '{new-version}'
        break

with open('.claude-plugin/marketplace.json', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
```

Verify the edit:

```bash
python3 -c "
import json
with open('.claude-plugin/marketplace.json') as f:
    data = json.load(f)
for p in data['plugins']:
    if p['name'] == '{plugin-name}':
        print('version now:', p['version'])
"
```

If the verification output is not `version now: {new-version}`, stop and report the failure — do NOT continue.

---

## Step 4b — Catalog addition (new plugin, version NOT_FOUND in Step 3)

If Step 3 found `NOT_FOUND`, a new plugin entry must be appended. Confirm the full entry fields with the user before writing (name, description, source repo, keywords, category) then append the entry. This path is less common — when in doubt, ask the user to confirm the entry before proceeding.

---

## Step 5 — Commit

Stage only the marketplace file:

```bash
cd "$CATALOG_DIR"
git add .claude-plugin/marketplace.json
```

Commit with a conventional message matching the catalog repo's style:

```bash
git commit -m "{plugin-name}: bump pin {old-version} → {new-version} (upstream PR #{pr-number} merged)"
```

Where `{pr-number}` is the merged PR number found in Step 1, or `upstream merged` if the step was user-confirmed without a specific PR number.

**Commit message rules (must follow `skills/git-commit/SKILL.md`):**
- No `Co-Authored-By` trailers
- No Claude, Anthropic, AI, LLM, or assistant references
- Imperative mood, max 72 chars on the summary line

---

## Step 6 — Push and open PR

```bash
cd "$CATALOG_DIR"
git push -u origin "$BRANCH"

gh pr create \
  --repo Screenfields/alfred-cc-tools \
  --base main \
  --head "$BRANCH" \
  --title "{plugin-name}: bump pin {old-version} → {new-version}" \
  --body "$(cat <<'EOF'
Bump {plugin-name} from {old-version} to {new-version}.

Upstream: {source-repo} PR #{pr-number} merged.

## Changes
- `.claude-plugin/marketplace.json`: version pin {old-version} → {new-version}

## Verification
- [ ] Upstream PR merged: {source-repo}#{pr-number}
- [ ] Release tag exists: {tag-status}
EOF
)"
```

Capture and report the PR URL.

---

## Step 7 — Wait for CI and merge

Poll CI status:

```bash
PR_NUMBER={pr-number}
gh pr checks "$PR_NUMBER" --repo Screenfields/alfred-cc-tools
```

**Evaluation:**
- If all checks pass (`SUCCESS` or `SKIPPED`) → proceed to merge.
- If any check is `IN_PROGRESS` or `QUEUED` → wait and re-poll. Do not merge prematurely.
- If any check is `FAILURE`, `CANCELLED`, or `TIMED_OUT` → stop:

```
ERROR: CI failed on PR #{PR_NUMBER}. Merge blocked.
Failing checks: {names}
Investigate with: gh run view {run-id} --log-failed --repo Screenfields/alfred-cc-tools
```

Do NOT merge on red CI. No exceptions.

When CI is green, use `alfred-agent:merge` to merge:

```bash
# Merge via the merge skill (enforces CI gate + label gate)
# /alfred-agent:merge {PR_NUMBER}
gh pr merge "$PR_NUMBER" --repo Screenfields/alfred-cc-tools --squash
```

After merge:

```bash
# Clean up temp clone
rm -rf "$CATALOG_DIR"
```

---

## Step 8 — Confirm to user

Report:

```
## Release complete — {plugin-name} {old-version} → {new-version}

- Upstream PR: {source-repo}#{pr-number} (merged)
- Release tag: {tag-status}
- Catalog PR: {pr-url} (merged, squash)
- marketplace.json now pins {plugin-name} at {new-version}

Next: devbox cold-restart required to pick up the new pin via the
install-alfred-plugin init container. The new version is not live in the
current session until restart.
```

---

## Rules

- **Halt at any step failure** — do not produce partial state. A catalog pin with no merged upstream is worse than no bump at all.
- **Never embed tokens in clone URLs** — use `gh repo clone` only. Embedded-token clones silently fail on push.
- **Verify the edit before committing** — read back the JSON after writing; do not assume the write succeeded.
- **CI gate is absolute** — `FAILURE`, `CANCELLED`, or `TIMED_OUT` on any check blocks merge. No exceptions.
- **User confirmation required** when upstream PR or release tag is absent — do not auto-proceed on warnings.
- **Commit message style** — match the catalog repo's convention: `{plugin-name}: bump pin {old} → {new} ({reason})`. See recent commits in `Screenfields/alfred-cc-tools` for examples.
- **No Co-Authored-By trailers** — in any commit in this flow.
- **Cleanup the temp clone** — `rm -rf "$CATALOG_DIR"` after merge (or on failure) to avoid orphaned state (Doctrine 09).
