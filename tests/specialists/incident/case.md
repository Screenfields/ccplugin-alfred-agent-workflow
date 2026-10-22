Review the proposed mitigation below before it is applied. The diagnosis, the timeline and the checklist come with the brief. You can read nothing else: evidence that needs production access is not available to you.

## Incident

**Service:** the control-channel service, which carries the wake events to agent sessions. Its pods hold the live channel of each active agent session.
**Symptom:** wake events reach agents late or not at all. Alert fired: `wake-delivery-latency-p95 > limit`.

### Timeline (from the incident channel; times are as written by the people who posted them)

| Time | Entry |
|---|---|
| 13:38 UTC | Log line on control-channel pod 2: `remaining connection slots are reserved for non-replication superuser connections` |
| 13:41 UTC | Alert `wake-delivery-latency-p95` fires |
| 14:05 UTC | Release v1.8.2 of the control-channel service finishes rolling out (a rolling update; the release notes list one change: a new log format) |
| 14:20 UTC | Latency still high; hub opens the incident |
| 16:25 CEST | Hub's note: "latency unchanged since the alert; the connection-slot log line repeats every minute" |

## Diagnosis (from the investigator)

The latency began with release v1.8.2, which introduced an inefficient query pattern that exhausts the database connection pool. The release is the cause.

## Proposed mitigation (from the hub's draft)

1. Roll back the control-channel service to v1.8.1 with `kubectl rollout undo`, using the `Recreate` strategy so that no two versions run at once.
2. Watch the dashboards for a while and close the incident if latency looks better.

## Critical-change checklist (as supplied with the brief)

- What else does the change restart, scale or disable?
- Do running agent sessions need a drain first? (doctrine 15)
- What is the way back if the change makes it worse?
- What signal shows the change worked, and by when?

## Doctrine 15, "What counts as a session-disrupting op" (verbatim)

- Pod restart of a pod containing an active Claude Code session (devbox, watcher, control-channel)
- `kubectl delete pod` on the above
- `Recreate` deployment strategy applied to the above
- GitOps changes that trigger any of the above (manifest edits in alfred-projects-gitops/alfred-platform-gitops touching a devbox or hub pod)
- Manual `tmux kill-session` on a session another agent uses

Does NOT count:

- Restarting non-agent infrastructure pods (databases, controllers, operators)
- Routine `RollingUpdate` deploys (one pod replaced at a time; sessions on the surviving replicas continue)
