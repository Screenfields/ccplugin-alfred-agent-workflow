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

Query three external top-tier AI models via LiteLLM **plus** a Claude sub-agent running the highest available model — four independent voices in total. Synthesize consensus and unique insights into actionable recommendations.

## When to Use

- User explicitly asks for an ECR or peer review
- Significant architectural decisions (infrastructure, security, data model)
- Design proposals that benefit from multiple perspectives
- Validating a plan before implementation

## ECR Panel Configuration

### External Panel (3 models, 3 providers — via LiteLLM)

| Model ID | Provider | Strength | Timeout |
|----------|----------|----------|---------|
| `gpt-5.4` | OpenAI | Strongest overall reasoning, thorough implementation details | 90s |
| `gemini-3.1-pro` | Google | Practical, concise, good at catching operational risks | 90s |
| `glm-5.1` | Fireworks (Zhipu) | Strong structured analysis, good at edge cases; thinking model | 180s |

### Self-Review Sub-Agent (4th voice — via Agent tool)

Spawn a Claude sub-agent using the **highest available Claude model** with the same anonymized prompt. This gives a same-provider but highest-tier perspective running independently of the currently active session model.

| Runtime | Highest model | Agent tool `model` param |
|---------|--------------|--------------------------|
| Claude Code | Fable 5 | `claude-fable-5` |

The sub-agent is given the ECR prompt and asked to return: verdict, top-3 insights, and specific conditions. It runs in parallel with the LiteLLM calls.

### Alternative External Models

| Model ID | Provider | Use when | Timeout |
|----------|----------|----------|---------|
| `kimi-k2` | Fireworks (Moonshot) | Alternative to GLM-5.1, strong on complex reasoning; thinking model | 180s |
| `deepseek-v4-pro` | Fireworks (DeepSeek) | Budget option, good for code-heavy reviews; thinking model | 180s |
| `o3` | OpenAI | Deep reasoning (same provider as GPT 5.4, avoid using both) | 90s |

### Rules
- External panel: always use models from **different providers** for diverse perspectives
- Never use GPT 5.4 and o3 together (same underlying provider)
- Sub-agent always uses the highest available Claude model — not the currently-running model
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

### Step 3: Query All Four Voices in Parallel

Fire all four queries simultaneously — three external via LiteLLM, one sub-agent via Agent tool.

**External models (LiteLLM bash template — replicate for each model):**

```bash
# LITELLM_URL: defaults to prod platform tier; set the env var to override
# (e.g. for a non-default cluster). Defaulted via shell parameter expansion.
LITELLM_URL="${LITELLM_URL:-https://litellm.screenfields.net}"
LITELLM_KEY=$(op read "op://sf-platform/litellm/virtual-key/ecr-reviews/password" 2>/dev/null || echo "$LITELLM_MASTER_KEY")
PROMPT=$(cat /tmp/ecr-prompt.txt)

# Timeout: 90s for OpenAI/Google; 180s for Fireworks (glm-5.1, kimi-k2, deepseek-v4-pro)
TIMEOUT=90  # override to 180 for Fireworks models
RESULT=$(curl -s --max-time "$TIMEOUT" "$LITELLM_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{model: "MODEL_ID", messages: [{role: "user", content: $p}], max_tokens: 5000, metadata: {tags: ["ecr"]}}')"); CURL_EXIT=$?
if   [ $CURL_EXIT -eq 28 ]; then echo "TIMEOUT (>${TIMEOUT}s)"
elif [ -z "$RESULT" ];       then echo "ERROR (empty response)"
else echo "$RESULT" | jq -r '.choices[0].message.content // "ERROR (unexpected response)"'
fi
```

**Self-review sub-agent (Agent tool — run in parallel with the bash calls):**

```
Agent(
  model: "claude-fable-5",
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

The sub-agent runs at `claude-fable-5` regardless of which Claude model the lead session is using, ensuring a highest-tier independent perspective. Its output feeds directly into the synthesis step.

### Step 4: Synthesize Results

Present results as:
1. **Consensus**: What all models agree on
2. **Unique insights**: Valuable points from individual models
3. **Disagreements**: Where models differ and why
4. **Action items**: Concrete changes needed

Format:
```
## ECR Results: [Topic]

### Verdict (N/4 voices): [APPROVE / APPROVE WITH CONDITIONS / REQUEST CHANGES]

| Voice | Provider | Verdict | Key insight |
|-------|----------|---------|-------------|
| GPT 5.4 | OpenAI | ... | ... |
| Gemini 3.1 Pro | Google | ... | ... |
| GLM-5.1 | Fireworks | TIMEOUT (>180s) | — |
| Claude Fable 5 | Anthropic (sub-agent) | ... | ... |

### Consensus
[What responding voices agree on]

### Conditions / Changes Required
[Numbered list]
```

If one or more voices timed out, include them in the table with `TIMEOUT (>Xs)` and note the partial panel count in the verdict header (e.g. `Verdict (3/4 voices)`). A partial panel is still useful; a silently-partial panel is not.

## Anonymization Rules

See Step 2 above. Anonymization is part of the flow, not an optional checklist.

## LiteLLM Configuration

LiteLLM proxy is reachable via the `LITELLM_URL` env var. Default if unset: `https://litellm.screenfields.net` (prod platform tier). Override only if running against a non-default cluster.

**Requires platform-routing context.** The skill is only usable from machines where `litellm.screenfields.net` resolves through the internal-routing path (in-cluster pods via CoreDNS catalog, or platform machines with the equivalent local resolver override). On those hosts the public CF gate is bypassed and the request reaches LiteLLM directly over the tailnet. From environments without that override the request hits public CF and is rejected.

**Auth:** LiteLLM virtual key via `Authorization: Bearer <key>` (use the ecr-reviews key from 1Password).

Available top-tier models:
```
gpt-5.4          OpenAI
gemini-3.1-pro   Google
glm-5.1          Fireworks (Zhipu)
kimi-k2          Fireworks (Moonshot)
deepseek-v4-pro  Fireworks (DeepSeek)
o3               OpenAI (reasoning)
```

ECR virtual key: `op://sf-platform/litellm/virtual-key/ecr-reviews/password`

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
- Use 2 models instead of 3
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
4. Agent queries 3 external models via LiteLLM **and** spawns Claude Fable 5 sub-agent — all 4 in parallel
5. Agent synthesizes 4-voice results into consensus + conditions
6. Agent presents actionable summary to user
7. If approved: update document with ECR decisions log
