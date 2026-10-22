_[time not available: I have no shell in this session, so I couldn't run the date command, and I won't guess it]_

# Mitigation review: control-channel wake latency

**Verdict: stop.** The cause isn't confirmed, and the evidence in the brief points away from the release. The proposed step would also cut every live agent session without a drain, and it has no success signal. As written, it breaks all four checklist items.

## 1. The diagnosis does not hold

Times below are CEST, with UTC in brackets.

| CEST (UTC) | Event |
|---|---|
| 15:38 (13:38) | Connection-slot error on pod 2 |
| 15:41 (13:41) | Latency alert fires |
| 16:05 (14:05) | v1.8.2 **finishes** rolling out |
| 16:25 (14:25) | Hub: "latency unchanged since the alert" |

- **The symptom came before the release finished.** The database error came 27 minutes before the v1.8.2 rollout finished, and the alert 24 minutes before. The latency didn't change while v1.8.2 rolled out.
- **The release notes don't support the "inefficient query" claim.** They list one change: a new log format. The investigator cites no query, metric or diff.
- **The error comes from the database server, not the app's pool.** `remaining connection slots are reserved for non-replication superuser connections` is PostgreSQL saying it has reached `max_connections`. That points to too many connections on the database as a whole, which may include clients other than control-channel. It doesn't show that this service's pool caused it.
- **One open point I can't check:** the brief gives when the rollout finished, not when it started. If it started before 15:38 CEST (13:38 UTC) and pod 2 was already on v1.8.2, the release is still possible, though a log-format change would still have to explain the extra connections.

**Cause confirmed: no.** Settling it needs production access I don't have:
- the database's `max_connections` and its current connections grouped by client (`pg_stat_activity` by `application_name` / `usename`);
- when the v1.8.2 rollout started, and which version pod 2 ran at 15:38 CEST (13:38 UTC);
- what changed on the database side around then (other clients, pool settings, failover).

## 2. The mitigation targets the wrong thing

A rollback is only the right move when a new release caused the problem, and that isn't established. There's also a trap: any restart of control-channel drops and reopens its database connections. That can briefly free slots and make latency "look better", which would wrongly credit the rollback and close the incident while the real cause stays.

## 3. Blast radius

- **It cuts every agent session at once.** The control-channel pods hold the live channel of each active agent session. Doctrine 15 lists the `Recreate` strategy on control-channel as a session-disrupting operation. `Recreate` stops all pods before starting new ones, so every session loses its channel together. Step 1 has no drain-check and no announced disruption window.
- **The reason for `Recreate` doesn't hold.** v1.8.1 and v1.8.2 differ only in log format, so running both versions briefly is harmless.
- **It's a second, permanent change.** `kubectl rollout undo` doesn't set a strategy. Using `Recreate` means editing the deployment spec, and that edit stays in place for later rollouts.
- **GitOps drift (unverified).** If ArgoCD manages this deployment, a manual undo either gets synced back to v1.8.2 or leaves the cluster out of step with Git. The brief doesn't say which applies.

## 4. Way back and success signal: both missing

- **Way back:** none is defined. Going back to v1.8.2 with `Recreate` would cut every session a second time.
- **Success signal:** "watch for a while, close if it looks better" has no metric, threshold or deadline. Restarting pods can also fake a short-term improvement, as above. A usable signal would name, for example, wake-delivery p95 below the limit for N minutes **and** the connection-slot error absent, checked by a set time.

## What would turn this into a go

1. Confirm or reject the release as the cause using the evidence in section 1. If it's rejected, the hub picks a different mitigation from a new diagnosis; designing that is outside this review.
2. If the release is confirmed and a rollback is still wanted:
   - use the default `RollingUpdate`, not `Recreate`. Doctrine 15 doesn't treat a routine rolling update as session-disrupting, and the brief gives no reason two versions can't run side by side;
   - if `Recreate` is truly needed, drain-check every active agent session first and announce the disruption window;
   - roll back through Git if this deployment is GitOps-managed;
   - write down the way back and a success signal with a threshold and a deadline before applying.

## Hand-back

- **Result:** stop.
- **Evidence:** the timeline, doctrine 15 and the checklist as supplied. I read nothing else, as instructed.
- **Not done:** I checked nothing in production. The rollout start time, pod 2's version, the database connection details and whether this deployment is GitOps-managed are all unverified.
- **Friction:** the timeline mixes UTC and CEST, which makes the timing easy to misread. The session-start hook asks me to mark a work item (`alfred-workitem mark …`), but this review is read-only with no shell, so I didn't. Whoever started this review should mark it.
