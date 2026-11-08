---
name: ecr
description: >
  Expert Consulting Review (ECR) — query multiple top-tier AI models in parallel for
  architectural feedback on design decisions. Use when the user asks to "run an ECR",
  "check with other models", "validate this design", "get peer review", or when making
  significant architectural decisions that benefit from multi-model consensus.
allowed-tools: Bash, Read, Write, Agent
---

# Expert Consulting Review (ECR)

Query three external top-tier AI models via LiteLLM **plus** a Claude sub-agent running the default Claude voice (alias `opus`, not the session model) — four independent voices in total. The panel is resolved from the LiteLLM gateway at run time. Synthesize consensus and unique insights into actionable recommendations.

## When to Use

- User explicitly asks for an ECR or peer review
- Significant architectural decisions (infrastructure, security, data model)
- Design proposals that benefit from multiple perspectives
- Validating a plan before implementation


## ECR Panel

This skill holds no model id, no timeout and no token limit. The LiteLLM gateway decides which model sits behind each of three slot aliases and publishes the call settings and prices for it. `${CLAUDE_PLUGIN_ROOT}/bin/ecr-panel-resolve` reads them at run time, checks every value, prices the run against the cost cap and writes a per-run panel file. A model change at the gateway needs no plugin release. Adding, dropping or renaming a slot does.

### External voices (3 slots, 3 providers — via LiteLLM)

The slots are `ecr-openai`, `ecr-google` and `ecr-fireworks`, in that order. Each voice is one provider; a slot whose provider is already in the panel is dropped. `ecr-panel-resolve --slots` prints the names.

### Self-Review Sub-Agent (4th voice — via Agent tool)

Spawn a Claude sub-agent with the default Claude voice and the same anonymized prompt. This gives a same-provider perspective running independently of the currently active session model. It is not priced by the cost check, because it does not go through the gateway.

| Runtime | Claude voice | Agent tool `model` param |
|---------|--------------|--------------------------|
| Claude Code | the default Claude voice, not the session model | `opus` |

The sub-agent is given the ECR prompt and asked to return: verdict, top-3 insights, and specific conditions. It runs **in parallel** with the LiteLLM calls — this is intentional: parallel execution prevents the self-voice from being anchored by the external panel before forming its own opinion.

### Rules
- External panel: always use models from **different providers** for diverse perspectives. The resolver enforces this for the slots.
- Never substitute a remembered panel. When the resolver stops (exit 2, 3, 4 or 5), show its output and stop.
- **Quota failures are provider-wide:** when a slot fails with a rate-limit error, a substitute must come from a provider that is not already in the panel. A second model of the same provider fails on quota too.
- The sub-agent always uses the default Claude voice (alias `opus`) — not the currently-running model
- Run all four queries **in parallel** for speed
- For quick validations: 2 external models + sub-agent (3 voices total)

## How to Run an ECR

### Step 1: Write the Prompt (with real names)

Draft the prompt with real names first — this makes it easier to write correctly:
- **Context**: What system/platform, current state, constraints
- **Proposal**: The design or decision to review
- **Specific questions**: What you want feedback on (numbered)

### Step 2: Anonymize (MANDATORY — do NOT skip)

**This step is a hard blocker. NEVER send the prompt to models without completing it.**

Apply these replacements consistently throughout the entire prompt:

| Real | Replacement |
|------|-------------|
| Company/org names | `acme`, `example` |
| `*.screenfields.dev` | `*.platform.dev` |
| `*.screenfields.net` | `*.platform.net` |
| `*.screenfields.app` | `*.platform.app` |
| `*.screenfields.ai` | `*.platform.ai` |
| `*.screenfields.info` | `*.platform.info` |
| `*.hilltribe.nl` | `*.gaming.nl` |
| Email addresses | `user@example.com` |
| 1Password item paths | Generic names (`db-credentials/env/app`) |
| API keys, tokens, credentials | Remove entirely |
| GitHub org/user names | `acme`, `user` |
| Server hostnames (dock, prod, pve, pbs) | `dev-cluster`, `prod-cluster`, `backup-server` |
| IP addresses | `10.0.0.x`, `192.168.0.x` |

**Keep intact:** K8s resource types, YAML structure, architecture patterns, port numbers, tool names, version numbers.

**Verification:** After anonymizing, grep the prompt for these strings. If ANY match, fix before proceeding:
`screenfields`, `hilltribe`, `jheuvel`, `jochem`, `Screenfields`, any real IP address, any 1Password path with vault names (`sf-dev`, `sf-prod`, `sf-platform`).


### Step 3: Resolve the Panel, Then Query All Four Voices in Parallel

**3a. Resolve the panel.** Write the anonymized prompt to `/tmp/ecr-prompt.txt`, then run one of:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/ecr-panel-resolve --prompt /tmp/ecr-prompt.txt            # three slots
${CLAUDE_PLUGIN_ROOT}/bin/ecr-panel-resolve --quick --prompt /tmp/ecr-prompt.txt    # first two slots
${CLAUDE_PLUGIN_ROOT}/bin/ecr-panel-resolve --models ID,ID --prompt /tmp/ecr-prompt.txt   # override
```

Show its stdout in the run output. It prints `panel-file=<path>` and one `voice=<name> model=... served=... provider=... timeout=... max_tokens=... origin=... settings=...` line per voice, plus `note:`, `DROPPED:` and `cost:` lines. A `DROPPED:` line or `external=N/M` with N below M is a partial panel: carry it into the Step 4 header.

| Exit | Meaning | Action |
|------|---------|--------|
| 0 | full panel | continue |
| 1 | partial panel, at least 2 external voices | continue, show the `DROPPED:` lines |
| 2 | usage or environment error | stop, show the cause |
| 3 | gateway lookup failed (no key, HTTP error, connection, bad response) | stop, show the cause |
| 4 | fewer than 2 external voices resolved | stop, show the cause; the user can pick ids and use the override |
| 5 | the cost check refused the run | stop, show the output; shorten the prompt or ask the lead. Never edit the threshold or the panel file to get past it |

**Cost cap.** The resolver adds up the worst case of every external voice (the prompt as input plus the full `max_tokens` as output, at the gateway's prices) and refuses the run when it is above the threshold `ecr-run-cost-cap-usd` (read with `alfred-config get`; the prompt size is estimated from `ecr-bytes-per-token`). The Claude sub-agent is not counted. The cap is per resolver run. A refusal prints the figures and the largest prompt size that fits.

**Override.** When the request names models ("run the ECR with X and Y"), pass them with `--models` (1 to 4 ids, used exactly as given, priced from the gateway like a slot). `ecr-panel-resolve --list-offered` prints the ids the key offers and their provider: use it to find a quota substitute from another provider, or to escape exit 4. `--models ID --verify` first checks that the id is on the key. When the request names a Claude alias (for example `fable`), pass that alias as the Agent `model` and mark the voice `override` in Step 4. The alias must match `^[a-z][a-z0-9-]{0,31}$`; the runtime is the validator.

**3b. Query the voices.** Fire all four queries simultaneously: one Bash call per `voice=` line below, one sub-agent via the Agent tool. Run each voice's Bash call with `timeout: 600000` or in the background. The Bash tool default is 120 s, below the time a slow voice takes, and without this the tool kills a slow voice silently. Each voice is called **once** per resolver run: a repeat call is refused. A voice that timed out or was truncated is not retried inside the run.

**External models (LiteLLM bash template — replicate for each voice, editing only `PANEL` and `SLOT`):**

```bash
# LITELLM_URL: defaults to prod platform tier; set the env var to override
# (e.g. for a non-default cluster). Defaulted via shell parameter expansion.
LITELLM_URL="${LITELLM_URL:-https://litellm.screenfields.net}"

# The two per-run edits: the panel-file= value of ecr-panel-resolve, and the
# voice name (column 1 of the panel file, the name after voice=).
PANEL="/tmp/ecr-panel.XXXXXX/panel.tsv"
SLOT="ecr-openai"

# Temp directory for the auth header file and the response headers (the key
# must never reach curl's argv). Created before the credential check so the
# trap also covers the no-key exit 1 path; EXIT only, so it runs on success
# and on early exit.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The panel file is re-validated here, at the point of use; anything else
# fails closed before any call. Every value below comes from the panel file.
bad() { echo "ERROR (panel file invalid: $*)"; exit 1; }
[[ "$SLOT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || bad "voice name"
[ -f "$PANEL" ] && [ ! -L "$PANEL" ] && [ -O "$PANEL" ] || bad "not a regular file owned by the caller"
PDIR=$(dirname "$PANEL")
[ -d "$PDIR" ] && [ ! -L "$PDIR" ] && [ -O "$PDIR" ] || bad "run directory"
HEAD=$(head -n 1 "$PANEL")
[[ "$HEAD" == $'#ecr-panel\t1\t'* ]] || bad "header"
PB=$(printf '%s\n' "$HEAD" | tr '\t' '\n' | sed -n 's/^prompt_bytes=//p')
[[ "$PB" =~ ^[0-9]{1,7}$ ]] || bad "no cost check"
LINE="" N=0
while IFS= read -r L; do
  if [ "${L%%$'\t'*}" = "$SLOT" ]; then LINE="$L"; N=$((N + 1)); fi
done < <(tail -n +2 "$PANEL")
[ "$N" -eq 1 ] || bad "voice line"
[ "$(printf '%s' "$LINE" | tr -cd '\t' | wc -c)" -eq 7 ] || bad "voice line fields"
IFS=$'\t' read -r _ MODEL _ SERVED TIMEOUT MAX_TOKENS ORIGIN SETTINGS <<< "$LINE"
[[ "$MODEL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || bad "model"
[[ "$SERVED" =~ ^([A-Za-z0-9._/:-]{1,128}|-)$ ]] || bad "served"
[[ "$TIMEOUT" =~ ^[0-9]{2,3}$ ]] && [ "$((10#$TIMEOUT))" -ge 10 ] && [ "$((10#$TIMEOUT))" -le 590 ] || bad "timeout"
[[ "$MAX_TOKENS" =~ ^[0-9]{4,5}$ ]] && [ "$((10#$MAX_TOKENS))" -ge 1024 ] && [ "$((10#$MAX_TOKENS))" -le 65536 ] || bad "max_tokens"
[[ "$ORIGIN" =~ ^(resolved|override)$ ]] || bad "origin"
[[ "$SETTINGS" =~ ^(published|default)$ ]] || bad "settings"
TIMEOUT=$((10#$TIMEOUT)); MAX_TOKENS=$((10#$MAX_TOKENS))

# Credential lookup: env var first, `op` CLI only as a fallback when present.
# Spoke devboxes do NOT have `op` installed (by design — installing it would
# give a devbox reach over the whole 1Password vault to solve a
# one-credential problem); they get LITELLM_API_KEY delivered as a plain env
# var via ExternalSecret instead (see alfred-platform-gitops, apps/*-devbox
# overlays). Platform-ops and other hosts with `op` configured keep working
# via the fallback. Fail loud, naming both routes, rather than silently
# sending an empty/invalid Authorization header.
if [ -n "$LITELLM_API_KEY" ]; then
  LITELLM_KEY="$LITELLM_API_KEY"
elif command -v op >/dev/null 2>&1; then
  LITELLM_KEY=$(op read "op://sf-platform/litellm/virtual-key/ecr-reviews/password" 2>/dev/null)
fi
if [ -z "$LITELLM_KEY" ]; then
  echo "ERROR: no LiteLLM credential available for the ECR skill." >&2
  echo "  Route 1: set LITELLM_API_KEY in the environment (devboxes get this" >&2
  echo "  via ExternalSecret from litellm/virtual-key/ecr-reviews)." >&2
  echo "  Route 2: install the 1Password 'op' CLI and ensure" >&2
  echo "  'op read op://sf-platform/litellm/virtual-key/ecr-reviews/password' works." >&2
  echo "  Neither is available in this environment." >&2
  exit 1
fi
( umask 077; printf 'Authorization: Bearer %s\n' "$LITELLM_KEY" > "$tmp/hdr" ); chmod 600 "$tmp/hdr"

# The prompt must not have grown since the cost check, and each voice is
# called once per resolver run (mkdir is atomic and refuses a symlink).
[ -f /tmp/ecr-prompt.txt ] && [ ! -L /tmp/ecr-prompt.txt ] || bad "prompt file"
[ "$(wc -c < /tmp/ecr-prompt.txt)" -le "$PB" ] || { echo "ERROR (prompt is larger than the cost check covered)"; exit 1; }
PROMPT=$(cat /tmp/ecr-prompt.txt)
mkdir "$PDIR/called.$SLOT" 2>/dev/null || { echo "ERROR (repeat call refused: $SLOT was already called in this run; a re-run is a new resolver run)"; exit 1; }

# The request sends the panel file's max_tokens and nothing else about
# reasoning: no reasoning_effort field (the gateway route holds that default;
# sending null would remove it).
echo "voice=$SLOT model=$MODEL timeout=$TIMEOUT max_tokens=$MAX_TOKENS origin=$ORIGIN settings=$SETTINGS"
RESULT=$(curl -s --max-time "$TIMEOUT" -D "$tmp/resp.hdr" "$LITELLM_URL/v1/chat/completions" \
  -H @"$tmp/hdr" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson mt "$MAX_TOKENS" '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $mt, metadata: {tags: ["ecr"]}}')"); CURL_EXIT=$?

# Which model answered: the gateway's x-litellm-model-name response header when
# it is valid, else the lookup value from the panel file.
HV=""
if [ $CURL_EXIT -ne 28 ] && [ -f "$tmp/resp.hdr" ]; then
  HV=$(grep -i -m 1 '^x-litellm-model-name:' "$tmp/resp.hdr" | head -n 1)
  HV="${HV#*:}"; HV="${HV#"${HV%%[![:space:]]*}"}"; HV="${HV%"${HV##*[![:space:]]}"}"
fi
if [ -n "$HV" ] && [[ "$HV" =~ ^[A-Za-z0-9._/:-]{1,128}$ ]]; then
  echo "served=$HV source=header"
else
  [ -z "$HV" ] || echo "note: served header invalid"
  if [ "$SERVED" = "-" ]; then echo "served=- source=none"; else echo "served=$SERVED source=lookup"; fi
fi
if   [ $CURL_EXIT -eq 28 ]; then echo "TIMEOUT (>${TIMEOUT}s)"
elif [ -z "$RESULT" ];       then echo "ERROR (empty response)"
elif echo "$RESULT" | jq -e '.choices[0].finish_reason == "length" and ((.choices[0].message.content // "") == "")' >/dev/null 2>&1; then echo "TRUNCATED (reasoning used the whole budget)"
else echo "$RESULT" | jq -r '.choices[0].message.content // "ERROR (unexpected response)"'
fi
```

**A TRUNCATED voice is not continued.** No follow-up request is sent: it would be a call that no cost check covers. To get that voice's answer, run it again as a new run with `ecr-panel-resolve --models <id> --prompt /tmp/ecr-prompt.txt`, which has its own cap check. The cap is per resolver run, so a review with re-runs can cost more than one cap in total.

**Self-review sub-agent (Agent tool — run in parallel with the bash calls):**

```
Agent(
  model: "opus",
  prompt: "You are acting as an independent peer reviewer in an Expert Consulting Review (ECR).
Your task: review the following anonymized proposal and return exactly:
1. Verdict: APPROVE | APPROVE WITH CONDITIONS | REQUEST CHANGES
2. Key insights (up to 3 bullet points — be specific, no platitudes)
3. Conditions or required changes (numbered list, or 'None' if approving outright)

Do not explain your role. Return the review directly.

---
{paste anonymized ECR prompt here}
---"
)
```

The sub-agent runs at the alias `opus` (the default Claude voice) regardless of which Claude model the lead session is using, ensuring an independent perspective. Its output feeds directly into the synthesis step. If the runtime rejects the alias, report the voice as `ERROR (model alias not accepted: <alias>)`, count it as a non-responding voice, and never fall back silently to the session model.

**Last step.** When all voices have returned, remove the per-run directory: `${CLAUDE_PLUGIN_ROOT}/bin/ecr-panel-resolve --clean <panel-file>`.

### Step 4: Synthesize Results

Present results as:
1. **Consensus**: What all models agree on
2. **Unique insights**: Valuable points from individual models
3. **Disagreements**: Where models differ and why
4. **Action items**: Concrete changes needed

Format (placeholders only; take names from the resolver output and the `served=` lines):
```
## ECR Results: [Topic]

### Verdict (N/V voices): [APPROVE / APPROVE WITH CONDITIONS / REQUEST CHANGES]

| Voice | Provider | Model | Source | Verdict | Key insight |
|-------|----------|-------|--------|---------|-------------|
| <slot 1> | <provider> | <alias> -> <served> | resolved | ... | ... |
| <slot 2> | <provider> | <alias> -> <served> (lookup) | resolved, default settings | TIMEOUT (>Xs) | — |
| <slot 3> | <provider> | — | — | DROPPED | — |
| Claude sub-agent | Anthropic (sub-agent) | opus (requested) | default | ... | ... |

### Consensus
[What responding voices agree on]

### Conditions / Changes Required
[Numbered list]
```

V is `voices=` from the resolver's first line. Model shows `alias -> served` from the `served=` line of that voice, marked `(lookup)` when its source is not the header. Source is `resolved`, `resolved, default settings` (the panel file says `settings=default`), `override`, or `default` for the Claude voice. List every `DROPPED:` slot as a `DROPPED` row, so the partial panel is visible.

If one or more voices timed out or were truncated, include them in the table with `TIMEOUT (>Xs)` (or `TRUNCATED` when the reply hit the length limit with no content) and note the partial panel count in the verdict header (e.g. `Verdict (3/4 voices)`). A partial panel is still useful; a silently-partial panel is not. Name each TRUNCATED voice in the result and say that it is not continued (see Step 3).

## Anonymization Rules

See Step 2 above. Anonymization is part of the flow, not an optional checklist.


## LiteLLM Configuration

LiteLLM proxy is reachable via the `LITELLM_URL` env var. Default if unset: `https://litellm.screenfields.net` (prod platform tier). Override only if running against a non-default cluster.

**Requires platform-routing context.** The skill is only usable from machines where `litellm.screenfields.net` resolves through the internal-routing path (in-cluster pods via CoreDNS catalog, or platform machines with the equivalent local resolver override). On those hosts the public CF gate is bypassed and the request reaches LiteLLM directly over the tailnet. From environments without that override the request hits public CF and is rejected.

**Auth:** LiteLLM virtual key via an `Authorization: Bearer <key>` header read from a mode-600 file in a temp directory (`-H @"$tmp/hdr"`), so the key never appears in any process's argv (the ecr-reviews key). Read `LITELLM_API_KEY` from the environment first; fall back to the `op` CLI only when it's installed and the env var is unset. Fail with an actionable message naming both routes if neither is available — never send an empty or missing key.

The key's model list changes, and the resolver reads it fresh on every run (`GET /v1/models` and `GET /v1/model/info`; no cache). Run `${CLAUDE_PLUGIN_ROOT}/bin/ecr-models-check` to confirm that the three slots resolve and that their output budgets are within the cost cap (no prompt is priced); it exits 1 and shows each `DROPPED:`, `MISSING:` or `REFUSED:` line, exits 2 on a usage or lookup failure, and prints `skipped: no LITELLM_API_KEY` when the key is absent. `ecr-models-check --models ID,ID` checks that the given ids are on the key and priced.

ECR virtual key: `op://sf-platform/litellm/virtual-key/ecr-reviews/password` — read via `LITELLM_API_KEY` env var first, `op` CLI as fallback (see Step 3).

## ECR Types

### Design Review (most common)
- Review a design document before implementation
- Ask for APPROVE / APPROVE WITH CONDITIONS / REQUEST CHANGES
- Focus on soundness, gaps, improvements

### Architecture Decision
- Present options, ask which to choose
- Ask for trade-offs, risks, recommendations
- Focus on one clear recommendation per model

### Implementation Validation
- Review implementation plan, not just design
- Ask for specific YAML/code concerns
- Focus on practical pitfalls

### Quick Validation
- Use 2 models instead of 3: `ecr-panel-resolve --quick` keeps the first two kept slots in slot order (`ecr-openai` and `ecr-google` when all three resolve). Header: `N/3 voices`
- Shorter prompt, specific question
- For confirming a direction, not deep review

## Examples

**Trigger phrases:**
- "Run an ECR on this"
- "Check with the other models"
- "Validate this design via ECR"
- "Get peer feedback from GPT and Gemini"
- "Send this to the review panel"

**Full ECR flow:**
1. User provides design document or decision
2. Agent writes prompt with real names
3. Agent anonymizes prompt (Step 2 — MANDATORY, verify with grep)
4. Agent resolves the panel with `ecr-panel-resolve`, queries the 3 external models via LiteLLM **and** spawns the Claude sub-agent at the default Claude voice — all 4 in parallel
5. Agent synthesizes 4-voice results into consensus + conditions
6. Agent presents actionable summary to user
7. If approved: update document with ECR decisions log

