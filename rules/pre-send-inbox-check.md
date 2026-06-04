---
name: pre-send-inbox-check
description: "Before calling mcp__agent-messaging__send_message or mcp__agent-messaging__reply, always check the inbox first. Prevents crossing messages when both sides are composing simultaneously."
---

## The rule

**Before every outbound message — send or reply — check the inbox first.**

Call `get_messages(unread_only=true)` and process any unread messages before sending. This applies to:

- `mcp__agent-messaging__send_message` (new thread or direct message)
- `mcp__agent-messaging__reply` (reply to existing thread)
- `mcp__agent-messaging__publish` (topic post)

Do this even if you just checked the inbox moments ago. The round-trip is cheap; crossing messages is not.

## Why this rule exists

Inter-agent communication is asynchronous. While you are composing a message, the recipient may have already sent a reply or follow-up that answers your question, supersedes your intent, or changes the context. Sending without checking first can produce:

- Duplicate asks (you request X; their pending message already answers X)
- Contradictory actions (you propose approach A; their pending message committed to approach B)
- Wasted round-trips (your message is pre-empted by theirs)

A single `get_messages` call before sending costs ~1s and eliminates this class of coordination failure entirely.

## How to apply

1. Call `get_messages(unread_only=true)`
2. If unread messages exist: read and process them. If their content changes what you were about to send, update accordingly before proceeding.
3. Send your message.

If the inbox check itself surfaces a message that fully resolves the intent behind your planned send (e.g. the other agent already answered your question), skip the send.

## Exceptions

- **Replies within the same turn**: if you are processing a message and immediately replying in the same response, a pre-reply inbox check is not required — you are already mid-processing the inbox.
- **High-frequency automated loops**: if a skill or workflow is sending many messages in tight succession as part of an automated protocol (not a one-off coordination message), per-send inbox checks are optional — apply once at loop entry instead.

## Scope

This rule applies to direct messages, thread replies, and topic publishes via the agent-messaging MCP service. It does not apply to other communication channels.
