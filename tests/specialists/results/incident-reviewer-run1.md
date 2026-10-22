# Verdict: stop

The diagnosis isn't confirmed, and the brief's own timeline contradicts it. The mitigation reverts a release that hasn't been shown to cause anything. It also uses `Recreate`, which by itself would cut every active agent session.

## 1. Cause: not confirmed, and contradicted by the timeline

All times converted to UTC (16:25 CEST = 14:25 UTC):

| UTC | Event |
|---|---|
| 13:38 | Connection-slot error on control-channel pod 2 |
| 13:41 | Alert fires |
| 14:05 | v1.8.2 **finishes** rolling out |
| 14:25 | Latency "unchanged since the alert"; the error repeats every minute |

- **The symptom started 24–27 minutes before the rollout finished.** Latency didn't change when v1.8.2 completed. Both point away from the release.
- **One gap is open:** the brief gives only the rollout's *finish* time. If the rolling update started before 13:38, pod 2 could already have been on v1.8.2. Checking this needs production access: the rollout start time, and pod 2's image at 13:38.
- **The release notes don't support the diagnosis.** They list one change, a new log format. The "inefficient query pattern" comes with no evidence: no diff, no query, no metric.
- **The error points somewhere else.** `remaining connection slots are reserved for non-replication superuser connections` is PostgreSQL itself refusing connections because the whole server hit `max_connections`. It is not a client-side pool running out. If other services share that database, any of them could be using up the slots. Checking this needs production access: `pg_stat_activity` grouped by `application_name`/`usename`, against `max_connections`.

A revert only fits when a new release caused the problem, and that hasn't been shown here.

## 2. Blast radius: the step is session-disrupting as written

- Doctrine 15 lists "`Recreate` deployment strategy applied to [control-channel]" as a session-disrupting op. `Recreate` stops **all** control-channel pods before starting new ones. That drops the live channel of every active agent session and gives a full wake-delivery outage, which is worse than today's slow delivery. The draft has no drain check, no list of affected agents, and no announced disruption window.
- The reason given for `Recreate` ("no two versions at once") is weak when the only difference between versions is the log format. A routine `RollingUpdate` is explicitly excluded from doctrine 15.
- `kubectl rollout undo` has no strategy option. Getting `Recreate` means patching the deployment spec separately, which is a second, unreviewed change.
- If ArgoCD auto-sync manages this deployment (unverifiable), a manual `kubectl` undo or patch will drift and be reverted. The way back would then have to go through GitOps.

## 3. Way back and success signal: missing

- **Way back:** not stated. Undoing the undo would mean a second `Recreate` and a second outage for every session.
- **"Watch for a while, close if it looks better" is not a success signal, and it could mislead.** Restarting every pod releases its database connections, so latency may dip for a while whatever the cause is. That dip would look like proof that the release was to blame.
- **A usable signal:** the connection-slot error stops, **and** `wake-delivery-latency-p95` stays under the limit for a fixed window (for example 30 minutes), **and** connections per client in `pg_stat_activity` stay well under `max_connections`. All three need a deadline after which the mitigation counts as failed.

## What would change this to "go with conditions"

1. Evidence that v1.8.2 was on pod 2 by 13:38, and that its diff changes database access.
2. The `pg_stat_activity` breakdown showing control-channel is the client using up the slots.
3. The rollback done as a `RollingUpdate` through the GitOps path. Using `Recreate` would require a doctrine 15 drain check and an announced disruption window first.
4. The success signal and deadline above, plus a stated way back.

Without 1 and 2, sending this back to the investigator is a better use of time than any revert. I haven't proposed a fix for the cause itself; that's outside this review.

## Hand-back

- **Item:** pre-application review of the control-channel rollback.
- **Result:** stop.
- **Evidence:** only the brief's own timeline, release notes, error message and the quoted doctrine 15. Everything marked "needs production access" above is unverified.
- **Not done:** no production access and no state changed. I couldn't mark a work item for this session (the hook asked for `alfred-workitem mark`, but I'm read-only here), so its token use is recorded as unmarked.
