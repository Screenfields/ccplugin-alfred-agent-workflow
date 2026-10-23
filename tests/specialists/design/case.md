Review the design note below. It serves the work item quoted first. The sources it cites are quoted after it.

## Work item (repo Screenfields/ccplugin-alfred-agent-workflow, issue #141)

**Title:** Refuse a secret-looking command-line argument

**Success state:** A Bash command that carries a token-shaped argument is refused before it runs, with a message that says how to pass it by stdin. A command that passes the same secret by stdin runs normally.

**Acceptance criteria**

1. A Bash command containing a GitHub token (`ghp_` or `github_pat_` followed by at least 20 characters) as an argument is refused.
2. A Bash command containing an AWS access key id (`AKIA` followed by 16 uppercase letters or digits) is refused.
3. `gh auth login --with-token < /tmp/tok` is not refused.
4. The hook is registered in `hooks/hooks.json` and covered by `tests/secret-arg-guard.bats`.

**Bounds**

- In scope: Bash tool commands.
- Out of scope: Write and Edit tool input, tool output, MCP tool arguments.

## Design note: secret-arg guard

Precedent: none declared

**Problem.** The rule `secrets-via-stdin-never-cmdline` is text only. Agents still paste tokens into commands, where they reach shell history, process listings and the session transcript.

**Current state.** `hooks/hooks.json` has no `PreToolUse` entry today, so the design adds a new `PreToolUse` block with the matcher `Bash`.

**Design.**
- New script `hooks/secret-arg-guard.sh`. Claude Code runs it before each Bash call and passes the hook JSON on stdin.
- It reads `tool_input.command` with `jq` and tests it against a list of extended regular expressions kept in the script: `ghp_[A-Za-z0-9]{20,}`, `github_pat_[A-Za-z0-9_]{20,}`, `AKIA[0-9A-Z]{16}`.
- On a match it prints `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"<text>"}}` and exits 0. The reason names the rule and says to write the secret to a mode-600 file and pipe it via stdin.
- On any internal failure (`jq` missing, unparseable input, a regex error) the script exits 2, so that no secret passes unchecked.
- Only the Bash tool is covered. Write and Edit input is not scanned.
- Test file `tests/secret-arg-guard.bats` feeds hook JSON on stdin and checks the output: one case per pattern, one stdin case, one garbage-input case.

**Alternatives.**
- *Patterns in `config/thresholds.json`.* Rejected: the thresholds config cannot hold strings, so the patterns have to live in the script.
- *Scan the session transcript after the fact.* Rejected: by then the secret has already reached the history and the process list.

**Expected effect.** Secret handling gets safer, and agents follow the stdin rule more consistently.

## Source: hooks/hooks.json (PreToolUse and Stop entries, as in the repo now)

```json
"PreToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "\"${CLAUDE_PLUGIN_ROOT}/bin/alfred-workitem\" guard",
        "timeout": 5
      }
    ]
  }
],
"Stop": [
  {
    "hooks": [
      { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh\"", "timeout": 20 },
      { "type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/bin/alfred-workitem\" hook", "timeout": 5 }
    ]
  }
]
```

## Source: README.md, "One Stop entry" (excerpt on hook scripts)

> Hook-mode scripts use no `set -e`/`set -u` and always exit 0 (CI audits this); a syntax error would exit 2, which blocks, so CI also runs `bash -n` on every hook.

## Source: config/thresholds.json (excerpt)

```json
{
  "overrun-pct": 50,
  "wip-limit": 2,
  "model-setting-per-role": {
    "builder": {"tier": "medium", "effort": "medium"}
  },
  "waiting-label": "status:waiting-on-owner",
  "ready-state": "status:ready",
  "workable-states": ["status:ready", "status:in-progress"]
}
```

## Source: rules/secrets-via-stdin-never-cmdline.md

> Never pass a secret as a shell command-line argument, env-var prefix (`SECRET=... cmd`), heredoc literal, or here-string — these all leak to bash history, `ps`/process listings, audit logs, and the Claude Code session transcript. Write the secret to a mode-600 temp file (or use a process-substituted file descriptor), pipe via stdin (`cmd < /tmp/secret-file`), then shred/unlink. The terminal command itself must contain no secret material.
