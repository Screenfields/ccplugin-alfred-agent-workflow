---
name: standup
description: >
  Template the spoke standup process — standing up a new project/agent on the Alfred platform.
  Use when bootstrapping a new spoke (project, service, or plugin constellation member) that
  needs a devbox, messaging identity, lead CLAUDE.md, and gitops token. All outputs are drafts
  for human review; nothing is auto-committed.
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Spoke Standup

Orchestrate the artifacts needed to stand up a new spoke on the Alfred platform. Produces a
complete set of drafts — human reviews and commits each one. Not a one-shot auto-apply.

**Full doctrine:** `alfred-platform-docs/spoke-standup-playbook.md`

## When to Use

Use this skill when **all three** of the following hold:

1. **Three or more agents will be involved** — the new spoke will need to send/receive messages
   from at least two other platform agents (e.g., alfred-platform, project-manager).
2. **Cross-project scope** — the spoke owns infrastructure or capabilities that other projects
   depend on (e.g., a shared service, a new plugin source repo, a platform utility).
3. **Shared infrastructure is required** — the spoke needs a devbox K8s manifest, a gitops
   token-generator entry, or a messaging identity registration (any one of these qualifies).

Do NOT use for in-constellation skill additions (that's a skill-author → pin-bump loop).
Do NOT use for one-off scripts or throwaway namespaces.

**First consumer:** `alfred-agent-messaging` (alfred-platform action #17).

## Parameters

Collect these before starting. Ask the user if any are missing.

| Parameter | Type | Example | Notes |
|-----------|------|---------|-------|
| `project-name` | string (kebab-case) | `alfred-agent-messaging` | Becomes the messaging identity and K8s namespace |
| `project-category` | enum | `platform-service` | One of: `plugin-constellation`, `platform-service`, `application` |
| `required-permissions` | list | `["gitops-write", "k8s-namespace-alfred-agent-messaging"]` | Capabilities the lead role needs; drives token-generator scopes |

## Process

### Step 1: Confirm Parameters

State the three parameters back to the user and ask for confirmation before generating any
drafts. Do not proceed to Step 2 until confirmed.

```
Project name:     {project-name}
Category:         {project-category}
Permissions:      {required-permissions}

Proceed? (y/n)
```

### Step 2: Draft Devbox K8s Manifest

Produce a draft manifest file. Do NOT write it to any repo — output it as a code block for
human review.

Target location (for reference): `alfred-projects-gitops/apps/{project-name}/devbox.yaml`

```yaml
# DRAFT — review before committing to alfred-projects-gitops
# Target: alfred-projects-gitops/apps/{project-name}/devbox.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {project-name}-devbox
  namespace: {project-name}
  labels:
    app: {project-name}-devbox
    component: devbox
    project: {project-name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {project-name}-devbox
  template:
    metadata:
      labels:
        app: {project-name}-devbox
        component: devbox
        project: {project-name}
    spec:
      serviceAccountName: {project-name}-devbox
      containers:
        - name: devbox
          image: ghcr.io/screenfields/devbox:latest
          env:
            - name: AGENT_ID
              value: "{project-name}"
            - name: PROJECT_NAME
              value: "{project-name}"
          volumeMounts:
            - name: gh-lead-token
              mountPath: /var/run/secrets/gh-lead
              readOnly: true
      volumes:
        - name: gh-lead-token
          secret:
            secretName: {project-name}-gh-lead-token
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {project-name}-devbox
  namespace: {project-name}
---
apiVersion: v1
kind: Namespace
metadata:
  name: {project-name}
```

**Human action required:** Review this manifest. Adjust image tag, resource limits, additional
volume mounts, and any project-specific env vars. Commit to `alfred-projects-gitops` once
satisfied.

### Step 3: Suggest Messaging Identity

Per platform convention, the messaging identity is the project name.

```
Suggested identity: {project-name}

Registration step (human executes after devbox is running):
  mcp__agent-messaging__send_message — identity is set via X-Agent-ID header in .mcp.json
  Add to .mcp.json in the new spoke's repo:

  {
    "mcpServers": {
      "agent-messaging": {
        "command": "...",
        "env": {
          "X-Agent-ID": "{project-name}"
        }
      }
    }
  }
```

No auto-registration. The identity becomes active when the devbox first sends a message with
the `X-Agent-ID` header set.

### Step 4: Draft CLAUDE.md for the New Spoke

Output as a code block for human review. Do NOT write to any repo.

```markdown
# CLAUDE.md

Guidance for Claude Code sessions running as the **{project-name} lead-agent**.

## Lead-agent role

- **Messaging identity:** `{project-name}` (registered in agent-messaging service)
- **Category:** {project-category}
- **Required permissions:** {required-permissions}

## Repository structure

[Fill in once repos are created]

## Session startup checklist

1. Confirm SessionStart hook is registered in `.claude/settings.local.json`
2. Run `/alfred-agent:check-messages` to catch messages delivered while session was down
3. Check open GitHub Issues for current sprint

## Coordination

- **alfred-platform:** message for architecture decisions, infrastructure changes
- **project-manager:** message for scaffolding, new repo requests
- **alfred-cc-tools:** message for plugin/skill updates

## Cross-project doctrine

Reference: `alfred-platform-docs/doctrines/` (01–09)
Key rules:
- Verify claims about state before acting (Doctrine 01)
- Namespace-qualify artifact names in cross-agent messages (Doctrine 03)
- Lead-worker pattern for parallel work (Doctrine 06)
- Diagnostic cleanup contract — declare teardown at creation time (Doctrine 09)

## Skills available

Standard alfred-agent skills: develop, land, retro, messaging, git-commit, review, ecr
[Add project-specific skills as they are authored]
```

**Human action required:** Fill in repository structure, add project-specific sections, commit
to the new spoke's primary repo root as `CLAUDE.md`.

### Step 5: Draft Lead-Role Token-Generator Manifest

Output as a code block for human review. Do NOT write to any repo.

Target location (for reference): `alfred-platform-gitops/token-generators/{project-name}-lead.yaml`

The token-generator grants the lead role's GitHub App scoped write access to the project's
repos. Scopes are derived from `required-permissions`.

```yaml
# DRAFT — review before committing to alfred-platform-gitops
# Target: alfred-platform-gitops/token-generators/{project-name}-lead.yaml
#
# Scope mapping (required-permissions → GitHub App permissions):
#   gitops-write        → contents:write on {project-name}-gitops (if applicable)
#   k8s-namespace-X    → no GitHub scope; handled via K8s RBAC separately
#   administration:write → administration:write (for branch protection self-serve)
#
# Add/remove scopes below to match required-permissions.
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {project-name}-lead-gh-token
  namespace: {project-name}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: 1password-store
    kind: ClusterSecretStore
  target:
    name: {project-name}-gh-lead-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: "{project-name}-lead-gh-app"
        property: token
---
# GitHub App installation token generator
# References 1Password item: {project-name}-lead-gh-app
# Permissions to configure in the App installation:
#   contents: write       (for {project-name} repos)
#   pull_requests: write  (to open/merge PRs)
#   issues: write         (to file/close issues)
#   metadata: read        (required baseline)
# [Add further permissions from required-permissions list]
```

**Human action required:**
1. Create a GitHub App installation scoped to the new project's repos
2. Store the App private key in 1Password as `{project-name}-lead-gh-app`
3. Adjust scopes above to match `required-permissions`
4. Commit to `alfred-platform-gitops` — ESO re-mints within seconds of merge

### Step 6: Out-of-Band Escalation

Some spoke standups hit a self-referential dependency: the new spoke is needed to validate its
own auth token, but the token doesn't exist yet, so the spoke can't run.

**When this applies:**
- The spoke's own devbox validates its gitops token (e.g., cc-tools bootstrapping its own auth)
- The spoke is the agent that would normally approve its own gitops PR
- The spoke's messaging identity is needed to confirm receipt of the identity registration

**Pattern: use a human/admin as the out-of-band resolver**

```
Self-referential dependency detected: {project-name} cannot validate its own token
before the token exists.

Out-of-band resolution steps (human executes):
1. Admin creates the GitHub App installation manually (bypasses the spoke's auth flow)
2. Admin verifies token validity:
   curl -H "Authorization: Bearer $(cat /path/to/token)" \
        https://api.github.com/repos/Screenfields/{project-name}
3. Admin confirms to the spoke (via agent-messaging or direct) that the token is valid
4. Spoke proceeds with the rest of the standup checklist

DO NOT have the spoke attempt to use an unvalidated token — silent auth failures are
the most common cause of stale gitops state.
```

For detailed escalation doctrine, see `alfred-platform-docs/spoke-standup-playbook.md §
Out-of-Band Resolution`.

### Step 7: Summary Checklist for Human

After all drafts are produced, output this checklist for the human to work through:

```
## Spoke Standup Checklist — {project-name}

### Drafts to review and commit
- [ ] Devbox K8s manifest → alfred-projects-gitops/apps/{project-name}/devbox.yaml
- [ ] CLAUDE.md → {project-name} primary repo root
- [ ] Token-generator manifest → alfred-platform-gitops/token-generators/{project-name}-lead.yaml

### Manual registration steps
- [ ] Create GitHub App installation, store key in 1Password
- [ ] Confirm messaging identity active (first message sent with X-Agent-ID: {project-name})
- [ ] Message alfred-platform to add repo to lead-role token-generator manifest
- [ ] Verify gitops PR merged and token re-minted (ESO confirms within ~30s of merge)
- [ ] Message project-manager if new repos need scaffolding

### Out-of-band check
- [ ] Does {project-name} have any self-referential dependencies? If yes, follow Step 6.

### Smoke test (after devbox is running)
- [ ] alfred-platform action #17 pattern: send a test message from the new spoke
- [ ] Confirm receipt via mcp__agent-messaging__get_messages on the recipient side
- [ ] Check devbox logs for auth errors
```

## Output Format

Present all drafts clearly labeled with:
- **DRAFT [N/5]** header
- Target file path (for reference, not auto-committed)
- The content as a fenced code block
- A "Human action required" note at the end of each draft

After all drafts: output the Step 7 summary checklist.

## Rules

- **All outputs are drafts.** Never write files to external repos. Never commit on behalf of
  the human. Never run `git push` against gitops repos.
- **Ask before generating** (Step 1 confirmation). Producing drafts for the wrong project
  wastes review cycles.
- **Self-referential dependency check is mandatory.** Always include Step 6 output, even if
  it seems unlikely to apply — omitting it is the most common error in spoke standups.
- **Reference the playbook, don't inline it.** For edge cases not covered here, cite
  `alfred-platform-docs/spoke-standup-playbook.md` rather than inventing doctrine.
- **Identity = project-name, always.** Do not suggest creative identity names. The platform
  identity model uses project-name for all spoke agents (per retro #2 decision).
