---
type: doctrine
status: active
updated: 2026-07-25
description: "When state appears reverted after a trusted write, distinguish write-path rollback from read-path derivation (silent no-op write) before naming the cause."
read_when: "When debugging an 'I wrote X and X isn't there on read' symptom."
---

# 21. Read-path derivation vs write-path materialisation

## Rule

When state "appears reverted" after a write you trusted to land, **distinguish two mechanisms** before naming the cause:

1. **Write-path rollback** — a writer (reconciler, validator, controller, migration) ran after your write and mutated the field. The data was there, then got changed. Fix is on the writer side: exempt the field, respect a flag, change ordering.
2. **Read-path derivation** — the read path applies a default / shim / projection / computed-column / view when the underlying storage is in a particular state (NULL, empty, missing, schema-default). Your write may have been a **silent no-op** — for example, an UPDATE whose WHERE clause didn't match, or a jsonb-concat where one operand was NULL and propagated NULL through the expression. Fix is on the value: write a non-default explicit value that disables the derive-shim or matches the WHERE clause.

Both fire on the same symptom ("I wrote X and X isn't there on read"). **Misattribution shapes the wrong fix**, sometimes the wrong design. Always ask BOTH questions; if both gates fire negative, the data is genuinely lost (transactional bug — the rarer third path).

## Why it exists

The 2026-06-02 project-manager backup soft-merge incident. alfred-platform attempted to set `apps[]` on a project record via SQL UPDATE using `jsonb_build_array(...) || apps`. The next read showed the same shape as before the write — the apps[] still looked derived-from-tracks{} rather than explicit.

The misattribution: alfred-platform suspected PM's reconciler was regenerating `apps[]` from `tracks{}` on its next tick, "rolling back" the explicit write. But ADR-0008 explicitly forbids the reconciler from writing apps[] — reconciler is observation-only. The hypothesis was structurally inconsistent with documented behaviour.

The actual mechanism: PostgreSQL jsonb concat treats NULL as a propagating value. `NULL || jsonb_build_array(...)` evaluates to NULL, not to a single-element array. So the UPDATE was a **silent no-op** on records where `apps` was already NULL. The column stayed NULL. The next read activated PM's derive-shim — code that synthesises an apps[] view from tracks{} when the underlying column is NULL, for legacy-compat reasons — and emitted exactly the shape that had been there before, making it look like the write had been rolled back.

**Wrong attribution → wrong design.** If alfred-platform had committed to "reconciler is overwriting apps[]" as the cause, the PM#34 adopt-apps endpoint design would have been shaped around making the reconciler respect apps[] — which it already does. The actual fix was a different shape: write a non-NULL apps[] that disables the derive-shim by being present. Same symptom, completely different remediation, different downstream-design ripple.

The pattern is everywhere outside this specific incident:

- **Kubernetes status fields** — the API server computes / defaults / coerces. You write `spec.replicas: 3` and observe `status.readyReplicas: 0` — that's not status being rolled back, it's status being computed from a different source (the controller's observation of running pods).
- **Database views vs underlying tables** — a view recomputes on every read. An UPDATE on the underlying table that misses the view's predicate has no observable read-side effect.
- **CDN / cache layers** — a write to origin may not invalidate the cache. The read serves a stale snapshot that looks like a write rollback but is just cache cohabitation.
- **ORM lazy-load shims** — the read-time hydration may emit fields not in the explicit write (defaults, computed properties, lazy-loaded relationships).
- **PostgreSQL GENERATED columns** — written value is silently overridden by the expression.
- **jsonb defaults / derive-shims in store layers** — PM's case; widely seen in event-sourced or projection-based stores.

## How to apply

When state "appears reverted" after a write:

1. **First**: did the underlying storage actually receive the write?
   - Pre-flight check: re-run the write expression with a tracing READ wrapping it (e.g. SELECT first, UPDATE, SELECT again WITH `RETURNING *`).
   - If the write was a silent no-op (`UPDATE 0`, NULL-propagation, WHERE-mismatch), you've found a read-path-derivation case — fix the value to bypass the derive-shim. **doctrine 21 case.**
2. **Second**: if the write DID land in storage, does the read path transform it?
   - Check for views, computed columns, ORM hydration, status-field controllers, cache layers between writer and reader.
   - If yes, the read mechanism is the cause, not a writer rolling back. Trace the read path back to the storage layer to see what's actually persisted vs what's emitted.
3. **Third**: if storage matches what you wrote AND the read path is direct, NOW look for a writer that ran after you. Reconcilers, controllers, validators, migrations.
   - At this point you're in write-path-rollback territory — doctrine 21 isn't your tool, you need a different fix (exempt-field, ordering, flag).
4. **Fourth**: if writer ran but did NOT mutate the field, and storage doesn't match what you wrote, you're looking at a transactional bug (commit visibility, isolation level, race) — escalate.

Walk the ladder in order. Steps 1 + 2 are the read-path-derivation cases that doctrine 21 names. Step 3 is the write-path-rollback case most agents jump to first. Step 4 is the rarer transactional failure that's often misdiagnosed as one of the others.

## What this doctrine does NOT do

- **Does not say all read-path transformations are wrong** — derive-shims, default-on-NULL, computed columns, status fields are intentional design patterns. doctrine 21 is about NAMING the mechanism, not removing it.
- **Does not replace doctrine 01 (verify-claims-about-state)** — d01 is about verifying claims *before* acting. doctrine 21 is about interpreting verified-but-unexpected results. They run in series: d01 confirms the read is real, d17 names what's producing it.
- **Does not apply to async writes that haven't propagated yet** — if you write to a DB primary and read from a replica within the replication lag, you'll see stale data. That's an async-propagation case, not a derive-shim case. doctrine 21 fires when the read AND write hit the same storage and the storage's behavior produces the surprise.

## Worked examples

### Example 1 — PM backup soft-merge incident (canonical, 2026-06-02)

alfred-platform ran SQL `UPDATE projects SET apps = jsonb_build_array(...) || apps WHERE name = 'backup'`. Next read of the apps field returned the derive-shim's tracks-projected shape, not the freshly-set explicit value.

**Initial misattribution**: "PM's reconciler is rolling back my write." Wrong — reconciler is observation-only per ADR-0008.

**Actual mechanism (doctrine 21 case)**: `apps` column was NULL pre-write. `NULL || X = NULL` in postgres jsonb concat. UPDATE landed but was a no-op on that record. The column stayed NULL, the read activated the derive-shim (which builds apps[] from tracks{} when underlying NULL), and the result looked like the write had been undone.

**Fix that worked**: change the expression to `SET apps = jsonb_build_array(...)` (replace not append) — bypasses the NULL-propagation, materialises the column, disables the derive-shim on subsequent reads.

**Source**: `feedback_write_rollback_vs_read_compute.md` (alfred-platform memory).

### Example 2 — Kubernetes status field "rollback"

You patch a Deployment's `spec.replicas` from 3 to 5. Status keeps showing `readyReplicas: 3`. Initial reaction: "something rolled my patch back."

**doctrine 21 walk**:
1. Did the patch land? Check `spec.replicas` directly: shows 5. Write was real.
2. Is the read path transforming it? `status.readyReplicas` is computed by the Deployment controller from observed pod state, not stored. Until 2 new pods come up, the status reflects 3.

This isn't a write rollback. It's a read-path projection (status reflects observed state, not desired). Wait or investigate why pods aren't coming up — different fix shape entirely than "find the rolling-back writer."

### Example 3 — Cache layer between writer and reader

You update a CMS article body via the admin API. Visit the public URL; old content shows. Initial reaction: "the admin save failed."

**doctrine 21 walk**:
1. Did the write land in storage? Hit the DB directly: new content present. Write was real.
2. Read path: public URL goes through CDN edge → origin → DB. CDN has its own TTL.

Cache invalidation gap, not a write failure. Fix is purge/invalidate on save, not "make the save more reliable."

## Related doctrines

- [01-verify-claims-about-state.md](./01-verify-claims-about-state.md) — d01 covers verifying claims about state before acting. d17 covers interpreting verified state when it surprises you. Run in series.
- [13-prevent-at-write-boundary.md](./13-prevent-at-write-boundary.md) — d13 says fix bug-classes at the write boundary, not at cleanup-after. d17 names a specific class where the "write boundary" isn't where you think it is — the storage layer's interpretation of the written value is part of the boundary, and a value that hits a derive-shim's activation condition is effectively a no-op write even if the SQL returned success.
- [07-filesystem-truth-over-metadata.md](./07-filesystem-truth-over-metadata.md) — d07 applied to local outputs (frontmatter, summaries) is the same pattern: don't trust the metadata projection, trust the underlying state. d17 is the storage-layer version.
