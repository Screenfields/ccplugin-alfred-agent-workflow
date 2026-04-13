---
description: Initialize alfred-agent for this project
---

Initialize alfred-agent configuration for the current project and optionally set up user-level defaults.

## Config Hierarchy

Alfred uses a three-level config hierarchy:

```
/etc/alfred/config.json             # Global (system-wide, CF-Access credentials)
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
- Write `.alfred/config.json`:

```json
{
  "agent_id": "{chosen_name}"
}
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
- "CF-Access credentials are required to reach secret-service"
- "Contact platform admin to set up global config on this host"

### 8. Confirm Success

Display summary:
```
Alfred agent initialized for '{agent_id}'

Config hierarchy:
  Global:  /etc/alfred/config.json [EXISTS/MISSING]
  User:    ~/.config/alfred/config.json [EXISTS/MISSING]
  Project: .alfred/config.json [CREATED]

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools (via user credentials)
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

Config hierarchy:
  Global:  /etc/alfred/config.json ✓
  User:    ~/.config/alfred/config.json ✓
  Project: .alfred/config.json ✓

You can now:
  - Check messages: /alfred-agent:check-messages
  - Send messages: Use agent-messaging MCP tools
  - Access secrets: Use secret-service MCP tools
```

## Different Permission Levels

If a project needs elevated permissions (e.g., write access to secret-service):
1. Create a dedicated Linux user for that service
2. Set up that user's `~/.config/alfred/config.json` with appropriate token
3. Run the service as that user

This maintains clear permission boundaries without project-level token management.

## Reference

See: `docs/baseline/platform/alfred-platform-secrets-management.md` in alfred-platform repo for full documentation on the config hierarchy.
