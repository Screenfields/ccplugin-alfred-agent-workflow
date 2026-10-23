---
name: refine
description: >
  Lead-side skill that runs the analyst and readiness reviewer pair, new to ready. Briefs the
  analyst for a work item, sends the result to a fresh readiness reviewer, loops the findings
  to the same pair until the reviewer passes or the failed-review-max limit sends it to the hub,
  then hands the pass to the lead. Edits nothing.
allowed-tools: Agent, SendMessage, Skill, Bash, Read
---

# Refine — the analyst and readiness reviewer pair, new to ready

Lead-side procedure for the transition from new to ready (routed rule `work-and-review-in-pairs`, "Review" paragraph of `agreement/lead.md`). The lead runs this skill in its own session. The skill edits nothing: it never sets the ready state and never changes the item. The lead applies the body and sets ready, with the owner's approval where Size requires it (`agreement/lead.md`).

The steps are named, not numbered. Run them in this order.

## Read the item

Read the work item named in the request: body, comments and linked items. Note the item reference (repo and number) for the briefs. If the request names no item, stop and ask for the item.

## Brief the analyst

Start the `analyst` specialist (`agents/analyst.md`) as a subagent with the Agent tool. The brief links the work item and states purpose, end state and bounds:

- Purpose: take the item from new to ready.
- End state: a new body under the template's fixed headings, plus the open questions with options and a recommendation, and the split proposal if the item holds two deliverables.
- Bounds: return the new body as the output. Do not edit the item, do not set labels, do not open items.

Keep the agent ID the Agent tool returns for the analyst. Every later message to the analyst goes to that ID.

## Send to a fresh reviewer

Start a fresh `readiness-reviewer` specialist (`agents/readiness-reviewer.md`) with the Agent tool. Its brief links the item and carries the analyst's new body and the analyst's open questions. Say in the brief that the item on GitHub still holds the old body, so the reviewer checks the carried body and not the item. It checks the carried body against the ready transition and returns pass or fail, the failed checks in order, and its expected class if it differs. Open questions do not count as a fail by themselves: the reviewer fails the body only if a question leaves something the builder would have to invent. Keep the agent ID of this reviewer too.

## Loop on a fail

On each fail, first count the failed rounds, before sending any findings. Read the limit with `alfred-config get failed-review-max`. The fail that reaches that number escalates instead of looping: stop, and send the escalation to the hub with the messaging skill. This is the "hit a review or overrun limit" case in the Escalate paragraph of `agreement/lead.md`. The escalation carries the item reference, the last body, and every finding. Do not hand over a fail as a pass.

For a large or very large item, a fail whose only failed check is the missing owner approval is not looped and does not count toward the limit. Hand it to the lead with the reviewer's output, the body and the open questions. The lead obtains the approval under Size in `agreement/lead.md`, and the lead re-runs the reviewer after the approval.

Below the limit, send the reviewer's findings to the same analyst with SendMessage to the analyst's agent ID. Do not start a new analyst: the analyst keeps its context for the fix. Send the analyst's revised body to the same reviewer with SendMessage to the reviewer's agent ID, because the reviewer checks against its own findings. Repeat until the reviewer passes.

## Keep what is not the skill's to decide

The analyst's open questions and split proposals go to the lead as they are. Do not answer a question and do not open the split items.

## Hand over

Hand the pass to the lead, with the reviewer's output, the body, and the analyst's latest open questions and split proposals.
