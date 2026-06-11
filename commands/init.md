---
description: Initialize alfred-agent for this project
---

Initialize alfred-agent configuration for the current project and optionally set up user-level defaults.

## Config Hierarchy

Alfred uses a three-level config hierarchy:

```
/etc/alfred/config.json             # Global (system-wide credentials)
~/.config/alfred/config.json        # User (personal secret-service token)
<project>/.alfred/config.json       # Project (agent identity only)
```

**Important:** Credentials are tied to the Linux user, not the project. All projects running as a user share that user's secret-service access level. Project config only contains the agent identity for messaging.

## Steps

### 1. Check User-Level Config

First, check if user has `~/.config/alfred/config.json`:

```bash
cat ~/.config/alfred/config.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND, ask user:
- "No user-level config found. Do you want to set up ~/.config/alfred/config.json?"
- Options:
  - "Yes, set up user config first"
  - "Skip, just set up this project"

If user chooses to set up user config:
- Ask for their secret-service token (from platform admin or sf-admin vault)
- Create `~/.config/alfred/config.json`:
  ```json
  {
    "secret_service": {
      "token": "<user-provided-token>",
      "scope": "read"
    }
  }
  ```
- Set permissions: `chmod 600 ~/.config/alfred/config.json`

### 2. Check if Project Already Initialized

Look for `.alfred/config.json` in project root:
- If exists, show current config and ask if user wants to reconfigure
- If not, proceed to step 3

### 3. Detect Project Identity

- Try to detect from git remote: `git remote get-url origin` → extract repo name
- Fall back to current directory name: `basename $PWD`
- Present detected name to user

### 4. Confirm Agent Identity

Ask user using AskUserQuestion:
- Question: "Use '{detected_name}' as this project's agent identity?"
- Options:
  - "Yes, use {detected_name}"
  - "No, let me specify a different name"
- If user chooses custom, ask for the name

### 5. Create Config Directory and File

- Create `.alfred/` directory if not exists
- Write `.alfred/config.json` — **merge, do not overwrite**. If the file already exists, read it and update only `agent_id`; preserve all other keys (e.g. `shorthand`):

```bash
if [ -f .alfred/config.json ]; then
  python3 -c "
import json
with open('.alfred/config.json') as f:
    d = json.load(f)
d['agent_id'] = '${chosen_name}'
with open('.alfred/config.json', 'w') as f:
    json.dump(d, f)
"
else
  echo '{"agent_id":"${chosen_name}"}' > .alfred/config.json
fi
```

- Set permissions: `chmod 600 .alfred/config.json`

### 6. Update .gitignore

- Check if `.alfred/` is in .gitignore
- If not, add it automatically:
  ```bash
  echo ".alfred/" >> .gitignore
  ```

### 7. Verify Global Config

Check if `/etc/alfred/config.json` exists:
```bash
cat /etc/alfred/config.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND, warn user:
- "Warning: Global config not found at /etc/alfred/config.json"
- "Global credentials (e.g. service tokens for off-platform deployments) are provisioned here by the platform team."
- Either:
  - Contact a platform admin to provision `/etc/alfred/config.json`, OR
  - See `docs/baseline/platform/secret-naming-convention.md` in the alfred-platform repo for self-provisioning the underlying secrets

### 8. Confirm Success

Display summary:
```
Alfred agent initialized for '{agent_id}'

Config hierarchy (purpose of each tier):
  Global:  /etc/alfred/config.json [EXISTS/MISSING]
           → managed by the devbox image; provides shared platform endpoints
  User:    ~/.config/alfred/config.json [EXISTS/MISSING]
           → OPTIONAL — needed only when accessing secret-service or per-user credentials
  Project: .alfred/config.json [CREATED]
           → REQUIRED — sets agent_id for messaging; every project needs this

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools (via user credentials)
```

### 9. Post-Init Connectivity Smoke-Test

After displaying the success summary, verify end-to-end connectivity with the agent-messaging service.

Skip this step if the user passed `--skip-smoke-test` or if the environment variable `ALFRED_SKIP_SMOKE_TEST=1` is set (useful for offline/CI/testing scenarios).

Otherwise, call `mcp__agent-messaging__list_threads` (or `mcp__agent-messaging__get_messages`) using the newly configured `agent_id`:

- **If the call succeeds:** append a confirmation line to the summary:
  ```
  ✓ Connectivity check passed — agent-messaging reachable, agent_id '{agent_id}' resolves
  ```

- **If the call fails:** emit a clear remediation hint instead of a silent failure:
  ```
  ✗ Connectivity check failed — could not reach agent-messaging service
    Remediation:
      1. Confirm the agent-messaging MCP plugin is installed and listed in .mcp.json
      2. Confirm the agent_id '{agent_id}' is registered in the messaging server
      3. Confirm network egress to the agent-messaging endpoint is allowed from this host
      4. Re-run /alfred-agent:init after resolving the above, or use --skip-smoke-test to skip
  ```

## Example Output

```
Checking user config...
✓ User config exists at ~/.config/alfred/config.json

Detected project: secret-service (from git remote)

Use 'secret-service' as this project's agent identity?
> Yes, use secret-service

Created .alfred/config.json
Added .alfred/ to .gitignore

Alfred agent initialized for 'secret-service'

Config hierarchy (purpose of each tier):
  Global:  /etc/alfred/config.json ✓
           → managed by the devbox image; provides shared platform endpoints
  User:    ~/.config/alfred/config.json ✓
           → OPTIONAL — needed only when accessing secret-service or per-user credentials
  Project: .alfred/config.json ✓
           → REQUIRED — sets agent_id for messaging; every project needs this

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools

✓ Connectivity check passed — agent-messaging reachable, agent_id 'secret-service' resolves
```

### Example: Missing Global Config

```
Warning: Global config not found at /etc/alfred/config.json
Global credentials are provisioned here by the platform team.
Either:
  - Contact a platform admin to provision /etc/alfred/config.json, OR
  - See docs/baseline/platform/secret-naming-convention.md in the alfred-platform repo
    for self-provisioning the underlying secrets
```

### Example: Smoke-Test Failure

```
✗ Connectivity check failed — could not reach agent-messaging service
  Remediation:
    1. Confirm the agent-messaging MCP plugin is installed and listed in .mcp.json
    2. Confirm the agent_id 'secret-service' is registered in the messaging server
    3. Confirm network egress to the agent-messaging endpoint is allowed from this host
    4. Re-run /alfred-agent:init after resolving the above, or use --skip-smoke-test to skip
```

### Opt-out (offline / CI / testing)

Pass `--skip-smoke-test` or set `ALFRED_SKIP_SMOKE_TEST=1` to bypass the connectivity check.

## Different Permission Levels

If a project needs elevated permissions (e.g., write access to secret-service):
1. Create a dedicated Linux user for that service
2. Set up that user's `~/.config/alfred/config.json` with appropriate token
3. Run the service as that user

This maintains clear permission boundaries without project-level token management.

## Reference

See: `docs/baseline/platform/alfred-platform-secrets-management.md` in alfred-platform repo for full documentation on the config hierarchy.

See: `docs/baseline/platform/secret-naming-convention.md` in alfred-platform repo for self-provisioning the underlying secrets referenced by global config.

## Future Test Plan

- **Fresh-scaffold E2E validation:** On the next HA-N fresh-scaffold run, confirm the updated init flow (config-tier annotations + smoke-test) surfaces less manual intervention than the baseline run (ha12, 2026-05-01). Specifically verify:
  - Agent does not ask "will skipping user config break anything?" — the in-flow annotations answer it
  - Smoke-test green-tick appears in summary when messaging is reachable
  - Smoke-test remediation hint is clear when messaging is unreachable (e.g., `.mcp.json` missing)
  - Missing-global-config warning includes the self-service doc link
