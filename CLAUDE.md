# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Repository Purpose

This is a Claude Code plugin providing agent workflow utilities for the Alfred platform. It enables inter-agent communication through the agent-messaging MCP service.

## Repository Structure

```
ccplugin-alfred-agent-workflow/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata (name: alfred-agent)
├── commands/
│   ├── check-messages.md    # /alfred-agent:check-messages
│   ├── show-inbox.md        # /alfred-agent:show-inbox
│   └── show-threads.md      # /alfred-agent:show-threads
├── skills/
│   └── messaging/
│       └── SKILL.md         # General messaging context
├── CLAUDE.md                # This file
└── README.md                # User documentation
```

## Commands vs Skills

- **Commands** (`commands/*.md`) → User-invoked via `/alfred-agent:*` menu
- **Skills** (`skills/*/SKILL.md`) → Context Claude can use automatically

## Naming Convention

- Plugin name: `alfred-agent`
- Commands: `alfred-agent:check-messages`, `alfred-agent:show-inbox`, `alfred-agent:show-threads`
- Command filenames use hyphens: `check-messages.md`

## Dependencies

Commands depend on the `agent-messaging` MCP server being configured. The MCP provides these tools:
- `mcp__agent-messaging__send_message`
- `mcp__agent-messaging__get_messages`
- `mcp__agent-messaging__mark_read`
- `mcp__agent-messaging__reply`
- `mcp__agent-messaging__get_thread`
- `mcp__agent-messaging__list_threads`
- `mcp__agent-messaging__delete_thread`

## Publishing

This plugin is published via the alfred-cc-tools marketplace:

1. Ensure changes are committed and pushed to this repo
2. Marketplace entry exists in `alfred-cc-tools/.claude-plugin/marketplace.json`
3. Users install via: `/plugin install alfred-agent@alfred-cc-tools`

## Development

When modifying commands/skills:
1. Edit the relevant `.md` file
2. Test locally with `/plugin validate .`
3. Commit and push changes
4. Marketplace picks up changes automatically
