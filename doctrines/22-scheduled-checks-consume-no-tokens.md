---
type: doctrine
status: active
updated: 2026-10-11
description: "Scheduled and periodic checks run as deterministic code and consume no LLM tokens; a model is woken only by an actionable event the check emits."
read_when: "When building or proposing anything that runs on a schedule to check state (health, drift, freshness, inbox, backups), or when about to schedule an agent turn to 'keep an eye on' something."
---

# Doctrine 22 — Scheduled checks consume no tokens

**Status:** Adopted 2026-10-11 (owner rule). Origin: the hub offered to "check the next few runs" of the new Kyverno drift probe (Screenfields/alfred-platform#1039). The owner ruled that no scheduled periodic check may consume tokens, and asked for that to be a generic rule.

## Rule

Every scheduled or periodic **check** runs as deterministic code with a mechanical pass/fail: a script, a probe, an alert rule, a watcher. It consumes **no LLM tokens**. A model is involved only when the check emits an **actionable event**, such as a firing alert, a new message or a failed record. The model is woken by that event; it never polls for it.

Never schedule a model turn to find out whether something is still fine. That rules out:
- a `/loop` or cron of an agent session;
- `ScheduleWakeup` or a remote trigger that re-runs a prompt;
- an agent promising to "keep an eye on the next runs".

## Why

- **Budget.** The platform runs on one shared subscription. A 15-minute agent poll is about 96 model turns a day, almost all of them empty; across the leads that adds up to a large standing cost for no information.
- **Determinism.** A coded check gives the same answer for the same state, can be unit-tested, and its history lives in metrics. A model reading the same state can answer differently from run to run, and leaves no comparable history.
- **Noise.** Empty wake turns produce text in lead sessions ("re-armed the watcher…"). The owner flagged this as a problem on 2026-10-11 (Screenfields/alfred-platform#1000).

## How to apply

- **A check is code.** A new check gets a mechanical pass/fail in code: a platform-health section, a PrometheusRule, a bash watcher. If you cannot write the pass/fail condition, the check is not defined yet. Define it; don't hand the judgment to a model on a timer.
- **Events wake models.** Route a failing check to an alert or a message, and let the wake bridge, a deterministic one-shot wait, start the session. A wake that carries nothing actionable produces no model output.
- **Stability is read, not watched.** To confirm a new check behaves, read its metric or record history once, or add a deterministic test. Do not schedule agent turns to watch it.
- **Polling is a degraded mode.** If the deterministic watcher cannot start (for example, the 15-minute `check-messages` loop used when the wake bridge fails), say so, and fix the watcher. Never keep the poll.
- **Not a check:** scheduled **work** that needs judgment is a job, with its own budget and owner. Examples are the Metis digestor and a nightly summarisation. It must not grow a "and also check whether X is healthy" step.

## Worked examples

- **Hub wake bridge** (`hub-wake-bridge`, Screenfields/alfred-platform#1000). A no-LLM bash wait replaced the `/loop 15m /alfred-agent:check-messages` inbox poll, and the session wakes only on new mail or alerts.
- **nudge-watcher.** Deterministic detection of deaf leads; it messages the hub only when a lead has unread mail past a threshold.
- **platform-health periodic + PrometheusRule.** The Kyverno drift section (Screenfields/alfred-platform#1046) runs every 15 minutes from a systemd timer, and `PlatformHealthFailing` routes to the hub only when a section fails.
- **Counter-example (2026-10-11).** After installing the Kyverno probe, the hub proposed to "check the next few runs" itself. The correct move is to read the probe's history from its journal or metrics when needed, and otherwise rely on the alert.
