# Doctrines (plugin copy)

The 22 cross-project doctrines, copied **verbatim** from their owner,
`Screenfields/alfred-platform` `docs/doctrines/` (at c41b1b4, alfred-platform#1137; doctrine 10 refreshed from main @ 03bcfaa for #127), so every
lead with the alfred-agent plugin has them without read access to a docs repo
(ccplugin-alfred-agent-workflow#121, AP-ADR0021).

- **Delivery:** `hooks/doctrines-context.sh` (SessionStart) injects one line per doctrine
  (number, title, the one-line rule from its `description`) plus the path of this directory.
  The full text is read on demand. Claude Code does not load plugin `rules/` folders, so this
  hook is the only delivery path.
- **Changes:** edit the doctrine in alfred-platform first, then copy it here unchanged in a
  plugin release. Never edit a doctrine only here.
- **Budget:** a hook string is capped at 10,000 characters. The index plus `rules/` is about
  8.3 KB today, and `tests/alfred-wake.bats` fails above 9,500, so a new doctrine that would break
  the cap is caught before release.
