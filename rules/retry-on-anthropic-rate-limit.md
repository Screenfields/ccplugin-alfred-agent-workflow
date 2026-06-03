---
name: retry-on-anthropic-rate-limit
description: "When the Anthropic API (or an Agent / Workflow call wrapping it) returns 'Server is temporarily limiting requests (not your usage limit) · Rate limited', sleep 10s and retry. Server-side throttle, not a usage cap — retries succeed."
---

## The rule

When you see this exact error from an Agent / Workflow / API call:

```
API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited
```

**Sleep 10 seconds, then retry.** Do not surface the error to the user as a failure. Do not ask "should I retry?" — just retry.

If the retry ALSO fails, sleep 20s and retry once more. After two failed retries (≥30s of waiting + 3 total attempts), surface the persistent rate-limit to the user as a real signal — it likely means an account-level or regional issue worth flagging.

## Why this rule exists

This is an upstream Anthropic-side server throttle, NOT a usage-limit error. It's transient by definition. The error message itself says "not your usage limit." Manual retries always succeed within ~10-30s. Treating it as fatal interrupts work that would otherwise complete.

## How to apply

**For Agent tool calls** that failed with this error: the error result includes `agentId: <id> (use SendMessage with to: '<id>' to continue this agent)`. Use **SendMessage** with that agent ID — that resumes the same agent with full context, not a fresh spawn. Pass a continuation prompt like "Continue with the original brief" or just "Continue" — the agent retains its instructions.

**For other API calls** (workflow steps, tool invocations that wrap the API): if the call surfaces this exact error, sleep 10s and call again with the same arguments. Idempotency considerations apply — for state-mutating calls (`Edit`, `Write`, `mcp__agent-messaging__send_message`, etc.) ensure the retry won't cause duplicate effects. Most reads are safe to blind-retry; writes need an idempotency-key check (did the previous call land before the rate-limit error? check before resending).

## What NOT to do

- Don't retry instantly without the 10s sleep — the throttle window is real, immediate retry hits the same limit.
- Don't loop forever — cap at 3 total attempts (initial + 2 retries) then surface.
- Don't conflate this with usage-limit errors. Usage-limit errors say "you have exceeded" or similar and should surface immediately as a hard blocker.

## When the user asks "did you fix it?"

State the retry succeeded. Don't apologize for the error — it wasn't yours.

## Scope

This rule is Claude-Code-specific — it references Anthropic's exact server-throttle error format. Other coding-agent runtimes (Codex, Gemini, etc.) have different rate-limit error shapes and would carry their own version of this rule in their respective tool layers.
