---
name: retry-on-anthropic-rate-limit
description: "When an Agent / Workflow tool call returns 'Server is temporarily limiting requests (not your usage limit) · Rate limited', sleep 10s and retry up to 2 more times. TOOL-CALL LAYER ONLY — main-inference rate-limits are invisible to the agent and cannot be self-recovered."
---

## Applies to: tool-call layer only

This rule covers **Case 1** — rate-limits that surface as tool call error results (Agent, Workflow, or other API-wrapping tool calls). In these cases you receive the error as a return value and can act on it.

**Case 2** — rate-limits on your own main-inference call — are invisible to you. They surface to the user or are handled by the harness. You cannot intercept or retry them. See [What this does NOT cover](#what-this-does-not-cover) below.

---

## The rule

When a **tool call** returns this exact error:

```
API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited
```

**Sleep 10 seconds, then retry.** Do not surface the error to the user as a failure. Do not ask "should I retry?" — just retry.

If the retry ALSO fails, sleep 20s and retry once more. After two failed retries (≥30s of waiting + 3 total attempts), surface the persistent rate-limit to the user as a real signal — it likely means an account-level or regional issue worth flagging.

## Why this rule exists

This is an upstream Anthropic-side server throttle, NOT a usage-limit error. It's transient by definition. The error message itself says "not your usage limit." Manual retries always succeed within ~10-30s. Treating it as fatal interrupts work that would otherwise complete.

## How to apply

**For Agent tool calls** that failed with this error: the error result includes `agentId: <id> (use SendMessage with to: '<id>' to continue this agent)`. Use **SendMessage** with that agent ID — that resumes the same agent with full context, not a fresh spawn. Pass a continuation prompt like "Continue with the original brief" or just "Continue" — the agent retains its instructions.

**For other tool calls** (Workflow steps, tool invocations that wrap the API): if the call surfaces this exact error, sleep 10s and call again with the same arguments. Idempotency considerations apply — for state-mutating calls (`Edit`, `Write`, `mcp__agent-messaging__send_message`, etc.) ensure the retry won't cause duplicate effects. Most reads are safe to blind-retry; writes need an idempotency-key check (did the previous call land before the rate-limit error? check before resending).

## What NOT to do

- Don't retry instantly without the 10s sleep — the throttle window is real, immediate retry hits the same limit.
- Don't loop forever — cap at 3 total attempts (initial + 2 retries) then surface.
- Don't conflate this with usage-limit errors. Usage-limit errors say "you have exceeded" or similar and should surface immediately as a hard blocker.

## What this does NOT cover

**Case 2 — main-inference rate-limits** occur between Claude Code and Anthropic's API before your response is generated. You never see the error. It surfaces to the user as a failed or dropped response. The retry must happen at the harness level or manually by the user — there is nothing for you to act on.

If you notice a pattern of rate-limits hitting the main session under high load, the structural mitigation is subagents — see below.

## Subagents as continuity mitigation

When Case 2 hits the main session, in-flight subagents spawned via the Agent tool are unaffected — they run independently and their results remain retrievable on resume. This is a structural argument for the lead-worker pattern beyond parallelism: it also provides **rate-limit continuity**. A main-session throttle loses at most one coordination step, not the entire in-flight workload.

This is not a reactive workaround. It is a baseline design principle: decomposing work into subagents means a main-session rate-limit is a brief interruption, not a loss of work.

## When the user asks "did you fix it?"

State the retry succeeded. Don't apologize for the error — it wasn't yours.

## Scope

This rule is Claude-Code-specific — it references Anthropic's exact server-throttle error format and the Agent tool's `SendMessage` continuation pattern. Other coding-agent runtimes have different error shapes and would carry their own version of this rule in their respective tool layers.
