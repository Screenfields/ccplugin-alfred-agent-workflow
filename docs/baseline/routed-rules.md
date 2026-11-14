# Routed rules

Baseline record of how a routed rule reaches a session (CCW-127, AP-ADR0021,
AP-ADR0031; extended by CCW-205). The code is the source of truth:
`hooks/routed-context.sh` holds the delivery.

## Where a rule goes

A new rule is one file in `rules/routed/`. Not in `rules/*.md`: that glob belongs
to `hooks/doctrines-context.sh`, which runs at SessionStart only and never reaches
a subagent. The routed files sit outside it, so no rule is delivered twice.

## File form

Frontmatter, then a body of one statement with its reason.

| Field | Value |
|---|---|
| `name` | the file name without `.md` |
| `roles` | a list of `all`, `lead`, `worker` |
| `work` | a list such as `code, design, operations, work item` |
| `severity` | `critical`, `major` or `minor` |

A body has no digit and no percent sign: a threshold lives in
`config/thresholds.json` and `tests/thresholds.bats` checks the bodies.

## Delivery

The hook reads the event from the stdin JSON.

- SessionStart, by the agent id in `.alfred/config.json`: no config gives nothing;
  `hub` and `alfred` get the `all` rules; any other id (a lead) gets the lead
  agreement, then the `all` and `lead` rules. `ALFRED_ROLE=worker` overrides this:
  the `worker` rules, never the agreement.
- SubagentStart, every agent type: the `all` and `worker` rules, nothing for leads.

Rules come in glob order. A hook string is capped at 10,000 characters and a test
keeps this one under 9,500.

## Tests that pin the rule sets

- `tests/agreement-rules-context.bats`: tag table, rule count, delivery per
  session, size cap.
- `tests/subagent-context.bats`: the rules a subagent gets and does not get.
- `tests/thresholds.bats`: no literal threshold in a rule body.

A new rule updates the tag table, the count and the delivery lists there.
