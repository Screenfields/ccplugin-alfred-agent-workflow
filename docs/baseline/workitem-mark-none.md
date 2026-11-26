# `mark none` text and warning

Baseline record for CCW-259 (version 2.54.2). The spec and its design review are the issue
https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/259 and its design comments
(AP-ADR0035 item 7: the design is recorded here in short form). The code is the source of truth:
`bin/alfred-workitem` (`cmd_mark`, `REMINDER`).

## Problem

The no-mark row of `commands/check-messages.md` and the unmarked reminder offered `mark none` as an
equal choice to marking an item. The store reads an empty `work_item` as an explicit clear, so a lead
that cleared its mark and kept working had every later request counted as unattributed, and
`AgentRunsWorkItemDeviation` fired.

## Rule

`mark none` is only for a session that makes no further model requests. Operational work (wakes, triage,
waiting) goes on the standing item of objective 1. The store counts requests after `mark none` as
unattributed; the local record stays silent (no reminder, no Stop record, no SessionEnd notice).
The README "Operational work" bullet is the one home of the rule for agents; this file is the design record.

## Where the text and the warning live

- No agent-read text (commands, skills, agents, rules, hooks, reminder) offers `mark none`; the no-mark row
  and the reminder name the standing item instead.
- `mark none` still works and still clears. It prints one stderr line containing "count as a deviation"
  whenever the `marked session ... -> none (cleared)` line prints (a store refusal included). The warning
  lives only in `cmd_mark`'s none branch, never in a hook path (SessionStart, UserPromptSubmit, Stop,
  SubagentStop, SessionEnd), so no token reaches the model from a hook. The stdout line is unchanged.
