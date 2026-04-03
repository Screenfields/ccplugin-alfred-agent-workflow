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

### Step 1: Prepare the Prompt

Write a clear prompt with:
- **Context**: What system/platform, current state, constraints
- **Proposal**: The design or decision to review
- **Specific questions**: What you want feedback on (numbered)
- **Anonymize**: Replace company names, domains, emails with generic placeholders

Template:
```
You are a senior [role] with expertise in [domain]. Please provide critical, constructive feedback.

## Context
[Current system state, constraints, scale]

## Proposal
[The design to review]

## Questions
1. Is this approach sound?
2. Are there blocking issues?
3. What improvements before implementation?
4. Rate: APPROVE / APPROVE WITH CONDITIONS / REQUEST CHANGES

Be concise and direct.
```

### Step 2: Query Models in Parallel

```bash
LITELLM_KEY=$(docker exec litellm env | grep LITELLM_MASTER_KEY | cut -d= -f2)
PROMPT=$(cat /tmp/ecr-prompt.txt)

# Run all 3 in parallel
curl -s http://localhost:5302/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg p "$PROMPT" '{model: "MODEL_ID", messages: [{role: "user", content: $p}], max_tokens: 5000}')" \
  | jq -r '.choices[0].message.content'
```

Use the Agent tool or parallel Bash calls to query all models simultaneously.

### Step 3: Synthesize Results

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

Before sending any prompt to external models:
- Replace company/org names with `example`, `acme`, etc.
- Replace real domain names (*.screenfields.dev) with `*.example.dev`
- Replace email addresses with `user@example.com`
- Replace 1Password item paths with generic names
- Remove API keys, tokens, and credentials
- Replace GitHub org/user names with generic names
- Keep technical details (K8s resources, YAML structure, architecture patterns) intact

## LiteLLM Configuration

LiteLLM proxy runs on dev-server at `localhost:5302`.

Available top-tier models:
```
gpt-5.4          OpenAI
gemini-3.1-pro   Google
glm-5            Fireworks (Zhipu)
kimi-k2.5        Fireworks (Moonshot)
deepseek-v3.2    Fireworks (DeepSeek)
o3               OpenAI (reasoning)
```

Auth: `Authorization: Bearer $LITELLM_MASTER_KEY`

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
2. Agent prepares anonymized prompt with context + questions
3. Agent queries 3 models in parallel via LiteLLM
4. Agent synthesizes results into consensus + conditions
5. Agent presents actionable summary to user
6. If approved: update document with ECR decisions log
