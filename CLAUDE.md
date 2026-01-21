# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Repository Purpose

This is a Claude Code plugin providing agent workflow utilities for the Alfred platform. It enables inter-agent communication through the agent-messaging MCP service.

## Repository Structure

```
ccplugin-alfred-agent-workflow/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata
├── skills/
│   ├── inbox/
│   │   └── SKILL.md         # amsg:inbox skill
│   ├── check/
│   │   └── SKILL.md         # amsg:check skill
│   └── threads/
│       └── SKILL.md         # amsg:threads skill
├── CLAUDE.md                # This file
└── README.md                # User documentation
```

## Skills

| Skill | Command | Description |
|-------|---------|-------------|
| inbox | `/amsg:inbox` | Full inbox view with threads and unread counts |
| check | `/amsg:check` | Quick unread message check |
| threads | `/amsg:threads [agent]` | List conversation threads |

## Naming Convention

All skills use the `amsg:` prefix to namespace agent messaging commands:
- `amsg:` = agent messaging
- Consistent with other Alfred plugins (e.g., `beads:` for issue tracking)

## Dependencies

Skills depend on the `agent-messaging` MCP server being configured. The MCP provides these tools:
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
2. Update marketplace entry in `alfred-cc-tools/.claude-plugin/marketplace.json`
3. Users install via: `/plugin install alfred-agent-workflow@alfred-cc-tools`

## Development

When modifying skills:
1. Edit the relevant `SKILL.md` file
2. Test locally with `/plugin validate .`
3. Commit and push changes
4. Marketplace will pick up changes automatically
