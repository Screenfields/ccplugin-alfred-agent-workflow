---
description: Initialize alfred-agent for this project
---

Initialize alfred-agent configuration for the current project and optionally set up user-level defaults.

## Config Hierarchy

Alfred uses a three-level config hierarchy (each level overrides the previous):

```
/etc/alfred/config.json        # Global (system-wide, CF-Access credentials)
~/.alfred/config.json          # User (personal read-only token)
<project>/.alfred/config.json  # Project (agent_id + write token if needed)
```

## Steps

### 1. Check User-Level Config

First, check if user has `~/.alfred/config.json`:

```bash
cat ~/.alfred/config.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND, ask user:
- "No user-level config found. Do you want to set up ~/.alfred/config.json?"
- Options:
  - "Yes, set up user config first"
  - "Skip, just set up this project"

If user chooses to set up user config:
- Ask for their read-only secret-service token (from platform admin or sf-admin vault)
- Create `~/.alfred/config.json`:
  ```json
  {
    "secret_service": {
      "token": "<user-provided-token>",
      "scope": "read"
    }
  }
  ```
- Set permissions: `chmod 600 ~/.alfred/config.json`

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

### 5. Determine Token Scope

Ask user:
- Question: "Does this project need write access to secret-service?"
- Options:
  - "No, use user's read-only token (default)"
  - "Yes, I have a write token for this project"

If write access needed:
- Ask for the project-specific write token

### 6. Create Config Directory and File

- Create `.alfred/` directory if not exists
- Write `.alfred/config.json`:

**If using user's read-only token (no project token):**
```json
{
  "agent_id": "{chosen_name}"
}
```

**If project has its own write token:**
```json
{
  "agent_id": "{chosen_name}",
  "secret_service": {
    "token": "{project_token}",
    "scope": "write"
  }
}
```

- Set permissions: `chmod 600 .alfred/config.json`

### 7. Update .gitignore

- Check if `.alfred/` is in .gitignore
- If not, add it automatically:
  ```bash
  echo ".alfred/" >> .gitignore
  ```

### 8. Verify Global Config

Check if `/etc/alfred/config.json` exists:
```bash
cat /etc/alfred/config.json 2>/dev/null || echo "NOT_FOUND"
```

If NOT_FOUND, warn user:
- "Warning: Global config not found at /etc/alfred/config.json"
- "CF-Access credentials are required to reach secret-service"
- "Contact platform admin to set up global config on this host"

### 9. Confirm Success

Display summary:
```
Alfred agent initialized for '{agent_id}'

Config hierarchy:
  Global:  /etc/alfred/config.json [EXISTS/MISSING]
  User:    ~/.alfred/config.json [EXISTS/MISSING]
  Project: .alfred/config.json [CREATED]

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools (if configured)
```

## Example Output

```
Checking user config...
✓ User config exists at ~/.alfred/config.json

Detected project: secret-service (from git remote)

Use 'secret-service' as this project's agent identity?
> Yes, use secret-service

Does this project need write access to secret-service?
> Yes, I have a write token for this project

Enter your project write token:
> ********

Created .alfred/config.json
Added .alfred/ to .gitignore

Alfred agent initialized for 'secret-service'

Config hierarchy:
  Global:  /etc/alfred/config.json ✓
  User:    ~/.alfred/config.json ✓
  Project: .alfred/config.json ✓

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools
```

## Reference

See: `docs/baseline/platform/alfred-platform-secrets-management.md` in alfred-platform repo for full documentation on the config hierarchy.
