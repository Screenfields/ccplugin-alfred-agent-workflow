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

Query multiple top-tier AI models via LiteLLM for independent architectural feedback on design decisions. Synthesize consensus and unique insights into actionable recommendations.

## When to Use

- User explicitly asks for an ECR or peer review
- Significant architectural decisions (infrastructure, security, data model)
- Design proposals that benefit from multiple perspectives
- Validating a plan before implementation

## ECR Panel Configuration

### Recommended Panel (3 models, 3 providers)

| Model ID | Provider | Strength |
|----------|----------|----------|
| `gpt-5.4` | OpenAI | Strongest overall reasoning, thorough implementation details |
| `gemini-3.1-pro` | Google | Practical, concise, good at catching operational risks |
| `glm-5` | Fireworks (Zhipu) | Strong structured analysis, good at edge cases |

### Alternative Models

| Model ID | Provider | Use when |
|----------|----------|----------|
| `kimi-k2.5` | Fireworks (Moonshot) | Alternative to GLM-5, strong on complex reasoning |
| `deepseek-v3.2` | Fireworks (DeepSeek) | Budget option, good for code-heavy reviews |
| `o3` | OpenAI | Deep reasoning (same provider as GPT 5.4, avoid using both) |

### Rules
- Always use models from **different providers** for diverse perspectives
- Never use GPT 5.4 and o3 together (same underlying provider)
- Default to 3 models; use 2 for quick validations
- Run all model queries **in parallel** for speed

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

### Step 3: Query Models in Parallel

```bash
# LITELLM_URL: defaults to dock tier; set the env var to override per cluster
# (e.g. https://litellm.screenfields.net for the prod platform tier on Hetzner —
# see alfred-platform#306). Defaulted via shell parameter expansion.
LITELLM_URL="${LITELLM_URL:-https://litellm.screenfields.dev}"
LITELLM_KEY=$(op read "op://sf-platform/litellm/virtual-key/ecr-reviews/password" 2>/dev/null || echo "$LITELLM_MASTER_KEY")
CF_ID="$CF_ACCESS_CLIENT_ID"
CF_SECRET="$CF_ACCESS_CLIENT_SECRET"
PROMPT=$(cat /tmp/ecr-prompt.txt)

# Run all 3 in parallel
curl -s "$LITELLM_URL/v1/chat/completions" \
  -H "CF-Access-Client-Id: $CF_ID" \
  -H "CF-Access-Client-Secret: $CF_SECRET" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{model: "MODEL_ID", messages: [{role: "user", content: $p}], max_tokens: 5000, metadata: {tags: ["ecr"]}}')" \
  | jq -r '.choices[0].message.content'
```

The CF Access credentials are available as environment variables (set in Claude Code settings).
Use the Agent tool or parallel Bash calls to query all models simultaneously.

### Step 4: Synthesize Results

Present results as:
1. **Consensus**: What all models agree on
2. **Unique insights**: Valuable points from individual models
3. **Disagreements**: Where models differ and why
4. **Action items**: Concrete changes needed

Format:
```
## ECR Results: [Topic]

### Verdict: [APPROVE / APPROVE WITH CONDITIONS / REQUEST CHANGES]

| Model | Verdict | Key insight |
|-------|---------|-------------|
| GPT 5.4 | ... | ... |
| Gemini 3.1 Pro | ... | ... |
| GLM-5 | ... | ... |

### Consensus
[What all agree on]

### Conditions / Changes Required
[Numbered list]
```

## Anonymization Rules

See Step 2 above. Anonymization is part of the flow, not an optional checklist.

## LiteLLM Configuration

LiteLLM proxy is reachable via the `LITELLM_URL` env var. Default if unset: `https://litellm.screenfields.dev` (dock tier). Override to `https://litellm.screenfields.net` for the prod platform tier (post-migration per alfred-platform#306).

**Auth requires two layers:**
1. CF Access headers: `CF-Access-Client-Id` + `CF-Access-Client-Secret` (from env vars)
2. LiteLLM virtual key: `Authorization: Bearer <key>` (use ecr-reviews key from 1Password)

Available top-tier models:
```
gpt-5.4          OpenAI
gemini-3.1-pro   Google
glm-5            Fireworks (Zhipu)
kimi-k2.5        Fireworks (Moonshot)
deepseek-v3.2    Fireworks (DeepSeek)
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
4. Agent queries 3 models in parallel via LiteLLM
5. Agent synthesizes results into consensus + conditions
6. Agent presents actionable summary to user
7. If approved: update document with ECR decisions log
