---
description: Initialize alfred-agent for this project
---

Initialize alfred-agent messaging for the current project.

**Steps:**

1. **Check if already initialized:**
   - Look for `.alfred/config.json` in project root
   - If exists, show current config and ask if user wants to reconfigure

2. **Detect project identity:**
   - Try to detect from git remote: `git remote get-url origin` → extract repo name
   - Fall back to current directory name: `basename $PWD`
   - Present detected name to user

3. **Confirm with user using AskUserQuestion:**
   - Question: "Use '{detected_name}' as this project's agent identity?"
   - Options:
     - "Yes, use {detected_name}"
     - "No, let me specify a different name"
   - If user chooses custom, ask for the name

4. **Create config directory and file:**
   - Create `.alfred/` directory if not exists
   - Write `.alfred/config.json`:
     ```json
     {
       "agent_id": "{chosen_name}",
       "tokens": {}
     }
     ```

5. **Update .gitignore if needed:**
   - Check if `.alfred/` or `.alfred/config.json` is in .gitignore
   - If not, suggest adding it (don't auto-modify)

6. **Confirm success:**
   - Display: "Initialized alfred-agent for project '{agent_id}'"
   - Explain: "You can now use /alfred-agent:check-messages to receive messages as '{agent_id}'"

**Example output:**
```
Detected project: secret-service (from git remote)

Use 'secret-service' as this project's agent identity?
> Yes, use secret-service

Created .alfred/config.json
Initialized alfred-agent for project 'secret-service'

You can now use /alfred-agent:check-messages to receive messages as 'secret-service'

Note: Consider adding .alfred/ to your .gitignore
```
