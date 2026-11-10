## Design

Design for CCW-202 (https://github.com/Screenfields/ccplugin-alfred-agent-workflow/issues/202), class medium. Source read: clone at `/tmp/ccw-opus`, main at `03d7bda`, plugin 2.44.0. Revised after design review round 1; see the change log at the end. Section 13 holds the lead's decisions and is the reference wherever this text says "decided".

Precedent: none declared

The repo has no `docs/adr/`. Its only baseline doc is `docs/baseline/reply-time-line.md`, which does not cover the ECR. `bin/ecr-panel-resolve` (CCW-193) is code that no baseline doc describes, so it is not a precedent. This design follows its patterns where they fit (validation at the boundary, exit-code table, `key=value` output lines, thresholds read by name with no script default, an EXIT-trap temp directory). The brief carries no platform passage.

### 1. Need

The ECR needs a fourth, same-provider voice that:

- runs on the most capable Claude model whose token price is at or under a limit X the owner sets, chosen when the ECR runs;
- reports which model actually answered, so the Step 4 table can show requested and served side by side;
- fails where everyone can see it and never drops silently to the session model or to an older model;
- stays independent: same anonymized prompt, run in parallel with the gateway voices, with no ability to write and no access to the lead's credentials.

Four questions follow, and each needs a source the skill can read: how the voice is run, which models exist (the candidate set), which is most capable (the ranking), and what each costs (the price).

### 2. Alternatives and recommendation

#### 2.1 How the voice runs

| Option | What it means | Pros | Cons |
|---|---|---|---|
| A. Headless voice | A script runs `claude -p --model <full id>` in an empty temp directory with no tools, with an allow-listed environment, and reads the stream-json output | A full model ID works headless (probe P1). The model is chosen per run, so a ranking and a price limit can apply. The served model is visible in the output (probe P4). Everything lives in this repo | The voice moves from the Agent tool to a Bash call. Plugin hooks run inside the child (section 4.3). About 4.7k tokens of hook context are added per call (P1, P2) |
| B. Fleet-wide alias remap | Keep the Agent sub-agent and set `ANTHROPIC_DEFAULT_FABLE_MODEL` fleet-wide through GitOps | No change to how the skill starts the voice | Changes every `fable` use on the platform. Needs the hub and a change in another repo. Gives one fixed model per alias, set by hand at each release. Cannot apply a ranking or X. Fails criteria 1 and 2 on its own |
| B2. Plugin-shipped agent file | Ship `agents/ecr-voice.md` with frontmatter `model: <full id>` and start it through the Agent tool by name | Keeps the Agent tool | The model is fixed in the plugin at release time, not chosen when the ECR runs, so it fails criterion 1 like B. It also puts a model ID in a shipped file that every release must edit. Whether the frontmatter accepts a full ID (the 11 files in `agents/` today use only `haiku`, `sonnet` and `opus`) was not verified, and it does not matter, because criterion 1 rules the option out either way |

**Only A is viable.** B and B2 are not real alternatives: neither can carry out the owner's rule ("most capable at or under X, at run time"). B is one fixed value for the whole fleet, and the Agent tool cannot get a different environment per call. B2 is one fixed value per release. A per-session variant of B, set in the lead's own environment, has the same flaw. The design reviewer decides whether this holds.

#### 2.2 Candidate source (which Claude models exist)

| Option | What it means | Pros | Cons |
|---|---|---|---|
| C1. Anthropic `GET /v1/models` | The script calls the API on each run | A new model appears with no edit. Has `line` (family) and `created_at` | No devbox has an Anthropic API key. The only credential is the Claude Code Max-subscription OAuth login, which the CLI reads itself; `--bare` also requires an API key (checked). Adding an API key means a new credential with per-token API billing, which is an owner trigger. Adds a network call and a trust boundary. Gives no price and no ranking (checked against the API reference) |
| C2. Claude Code alias (`--model fable`) | Use the alias the CLI resolves | No call, no credential | Lags: headless `--model fable` served `claude-fable-5-1` (P2). Gives one model per family. Fails the owner's request now |
| C3. Named threshold table | The candidate IDs sit in `config/thresholds.json` as one ordered table with prices | No call, no credential, deterministic, testable with fixtures | Each Claude release costs one table row and the delivery chain in section 9. A model not on the list is never chosen. The issue accepts this cost ("at most a one-line threshold change") |
| C4. Claude Code's model catalog cache | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/model-catalog/*-cc.json`, fetched by Claude Code from the server. The path `.catalog.config.models[]` gives `id`, `section` (`main` / `overflow`) and `runtime.family` | No call, no credential. A new model shows up without an edit: the newest file lists `claude-fable-5-2` in `main` | Undocumented internal file: format, file name and refresh can change with any Claude Code release. Gives no price and no ranking. This devbox holds two files: the current one and a 19-day-old one with extra keys (`organizationUuid`, `resolution`) that still lists `claude-fable-5-1` in `main`. `staleAt` is about one hour after `fetchedAt` in both. Whether a headless run refreshes it is not known |

**Decided (section 13, L1): C3 is the authority for the choice, and C4 is a warn-only detector.** The detector names a `main`-section model that is in neither the table nor the named list of deliberately unranked IDs. Its rules are in section 4.5. It never changes the choice or the exit code, and it is not a source in the sense of criterion 6 (section 6).

#### 2.3 Ranking (most capable)

| Option | What it means | Pros | Cons |
|---|---|---|---|
| R1. Order of the table | The table is ordered most capable first; row position is the rank | Explicit, predictable, one place to edit. Rank and price live in one row, so a release is one line | Lead judgment at each release. A model not on the list is ineligible (named by the detector) |
| R2. Price as proxy | The most expensive model at or under X counts as the most capable | No ordering to keep | It still needs the same per-ID price table (no machine-readable price source exists, section 2.4), so it saves no edit over R1. It misranks whenever a newer, more capable model is cheaper than an older one. That has happened: Fable 5.2 ($40 per MTok output) is cheaper than Fable 5.1 ($50), and Opus 4.5 ($25) cheaper than Opus 4.1 ($75) |
| R3. Family order plus version parsed from the ID | Family order in a threshold, then the highest `<major>-<minor>` in the ID | The family order changes rarely | IDs are not regular: the catalog holds `claude-haiku-4-5-20251001` (date suffix), `claude-sonnet-5` (no minor) and `claude-opus-4-8`. The API reference says of `line`: "do not infer a line from the `id`". It still needs a price per ID, so it saves no edit over R1 |
| R4. Ask a model | A model call picks | None that matter | Nondeterministic, costs tokens, no fixture test; conflicts with doctrine 18 |

**Recommendation: R1.** The price must be kept per ID anyway (section 2.4), so a table row has to be added at each release whatever the ranking. R1 then costs nothing extra, needs no ID parse, and cannot misrank by price.

#### 2.4 Price source

| Option | What it means | Pros | Cons |
|---|---|---|---|
| P1. Price column in the threshold table | Each row holds the list price in USD per million output tokens | No call. The lead copies one number from the Anthropic pricing page | Kept by hand. A row with no price is left out and named |
| P2. LiteLLM public price map | Fetch `model_prices_and_context_window.json` from GitHub on each run | Updated by a third party | A 3.5 MB fetch on each run, a new trust boundary and a validation step. In the part read (first 100k characters) there was no `claude-fable-5-2` key, only Bedrock-prefixed ones |
| P3. Cost reported by Claude Code after the call | `modelUsage.<id>.costUSD` in the result | Free | Known only after the call, so it cannot choose. Wrong for the model in question: for `claude-fable-5-2`, Claude Code 2.1.317 printed `unrecognized_model` on stderr and reported `costBasis: "unknown"`, with a figure below list price (P1) |

**Recommendation: P1.** P3 is not a real alternative for choosing. P2 is real but costs a fetch and a trust boundary for data that lags.

#### 2.5 Combined recommendation

- **Choice.** One threshold table, `ecr-anthropic-models`, ordered most capable first, with `{id, output-usd-per-mtok}` per row, and one threshold for X. The script `bin/ecr-anthropic-voice` takes the first valid row whose price is at or under X. It names each more capable row that was skipped because of X and each row it left out.
- **Run.** It runs the chosen model headless (A), with an allow-listed environment and a credential check before the call.
- **Detector.** Warn-only, it names any current `main` model that is in neither the table nor `ecr-anthropic-unranked`.

**Why the names avoid "claude-":** `tests/ecr-template.bats` test "9 no claude- string ..." is kept (it enforces criterion 1) and fails on any `claude-` substring in `SKILL.md`. A script named `ecr-claude-voice`, or a threshold named `ecr-claude-models`, would trip it, so the names use `anthropic`.

### 3. Components and boundaries

| Component | Change |
|---|---|
| `bin/ecr-anthropic-voice` (new, bash, `set -u`, `LC_ALL=C`) | Resolve, validate, check the credential, run headless, check the served model, report |
| `config/thresholds.json` | Four new keys (section 5) |
| `skills/ecr/SKILL.md` | The lines listed below. Names no model ID and no version |
| `README.md` | The `/alfred-agent:ecr` line (line 69) and the threshold paragraph (around line 426) name the four new thresholds and say the Claude voice is outside the cost cap |
| `tests/stub/claude`, `tests/stub/timeout`, `tests/stub/env` (new) | Test doubles (section 8). `timeout` and `env` record argv and environment names for the R3-B1 case, and are put on `PATH` only by `tests/ecr-anthropic-voice.bats`. Like every file in `tests/stub/`, the CI shellcheck glob covers them |
| `tests/helpers/ecr-anthropic.bash` (new) | Fixture builders (table, catalog files, stream, auth status) |
| `tests/ecr-anthropic-voice.bats` (new) | Behaviour tests |
| `tests/ecr-template.bats`, `tests/ecr-models-check.bats`, `tests/thresholds.bats` | Updated pins (section 8) |
| `.claude-plugin/plugin.json` | 2.44.0 to 2.45.0 |

**`SKILL.md` lines that must change** (line numbers at `03d7bda`):

| Line | Today | Change |
|---|---|---|
| 8 | `allowed-tools: Bash, Read, Write, Agent` | drop `Agent`; nothing else in the skill uses it |
| 13 | intro: "a Claude sub-agent running the default Claude voice (alias `opus`, ...)" | "a Claude voice run headless on the most capable Claude model at or under the price limit" |
| 31-39 | section "Self-Review Sub-Agent (4th voice — via Agent tool)", the runtime table with `opus`, and the "in parallel" paragraph | section "Claude voice (4th voice, headless)": the script, the four threshold names, the rule, outside the cost cap. The "in parallel" sentence stays |
| 45, 47 | Rules: "The sub-agent always uses the default Claude voice (alias `opus`)"; "2 external models + sub-agent" | "The Claude voice never runs on the session model and never falls back to another model"; "+ the Claude voice" |
| 107 | Cost cap: "The Claude sub-agent is not counted" | "The Claude voice is not counted; its price is bounded per token by the price limit" |
| 109 | Override: "pass that alias as the Agent `model`"; regex `{0,31}` | "pass it as `ecr-anthropic-voice --model <id>`"; the script's regex (section 4.1) |
| 111 | 3b: "one sub-agent via the Agent tool"; "Each voice is called **once** per resolver run: a repeat call is refused" | "one Bash call to `ecr-anthropic-voice`"; "Each gateway voice is called once per resolver run: a repeat call is refused. The Claude voice has no repeat guard (it is outside the cost cap); the skill calls it once per run" |
| 220-239 | the Agent block with `model: "opus"` and the paragraph after it | the script call, its exit table (section 4.6) and the served-check caveat (section 4.4) |
| 262 | Step 4 row `\| Claude sub-agent \| Anthropic (sub-agent) \| opus (requested) \| default \| ...` | `\| Claude voice \| Anthropic (headless) \| <requested> -> <served> \| <source>, limit <limit>, price <price> \| ... \| ... \|` |
| 271 | "Source is `resolved`, ..., `override`, or `default` for the Claude voice" | "... or, for the Claude voice, `resolved` or `override` with the limit and price" |
| 327 | Full ECR flow step 4: "spawns the Claude sub-agent at the default Claude voice" | "runs the Claude voice with `ecr-anthropic-voice`" |

Boundaries: `bin/ecr-panel-resolve`, the gateway template, the cost check and the anonymization are not touched. The Claude voice stays outside `ecr-run-cost-cap-usd`. The resolver's `voices=` already counts it as the +1 voice, so the `N/V voices` header is unchanged.

### 4. Interface of `bin/ecr-anthropic-voice`

#### 4.1 Arguments

```
ecr-anthropic-voice --prompt FILE              resolve, check the credential, run the voice, report
ecr-anthropic-voice --prompt FILE --model ID   override: run ID as given; no table, no limit
ecr-anthropic-voice --resolve                  resolve and report only; no claude call of any kind
```

- `--resolve` is exclusive with `--prompt` and `--model`. `--model` needs `--prompt`. Any other argument is a usage error (exit 2).
- `--prompt FILE`: a regular file, not a symlink, readable, 1 byte to 4 MiB (the resolver's `MAX_PROMPT_BYTES`).
- `--model ID`: must match `^[a-z][a-z0-9-]{0,63}$`, so a full ID or an alias such as `fable` is accepted, and a leading dash, uppercase, dots, spaces and metacharacters are refused.
- The script reads `ALFRED_THRESHOLDS` (as in the resolver, with the same `note:` line when set), `CLAUDE_CONFIG_DIR`, `HOME`, `TMPDIR` and `PATH` from its own environment. It reads one credential variable, `CLAUDE_CODE_OAUTH_TOKEN`, only to test that it is set and to pass it on (section 4.2); it never prints or logs it. The child gets only the allow-list in section 4.2.

#### 4.2 Child environment (allow-list) and login

**How the child is started (R3-B1).** No value of any environment variable may appear in any process's argv. `/proc/<pid>/cmdline` is readable by every user on the host, and `/proc` is mounted without `hidepid`. So the script never uses `env -i NAME=value` or a `NAME=value cmd` prefix. Both child commands, `claude auth status --json` and `claude -p`, go through one function:

```
ALLOW="HOME PATH TMPDIR CLAUDE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE"
run_child() {                       # run_child <command> [args...]: no value ever reaches argv
  (
    for n in $(compgen -e); do      # every exported name
      case " $ALLOW " in *" $n "*) ;; *) unset "$n" 2>/dev/null ;; esac
    done
    left=$(compgen -e | grep -vxF -f <(tr ' ' '\n' <<<"$ALLOW") || true)
    [ -z "$left" ] || { echo "ecr-anthropic-voice: cannot clear the environment: $(echo $left)" >&2; exit 2; }
    export ALFRED_ROLE=worker LANG=C.UTF-8 TMPDIR="${TMPDIR:-/tmp}"
    cd "$rundir" || exit 2
    exec "$@"
  )
}
run_child timeout 20 claude auth status --json < /dev/null > "$rundir/auth.json" 2> "$rundir/auth.err"
run_child timeout -k 5 "$CALL_TIMEOUT" claude -p --model "$MODEL" --effort "$EFFORT" ...   # section 4.3
```

- `unset` and `export` are bash builtins, so they start no process and put nothing in any argv.
- `exec` replaces the subshell. `timeout`'s argv, and then `claude`'s, holds only the flags, the model ID and the effort level.
- The token and the proxy variables (`HTTPS_PROXY` may carry a username and password) reach the child only in its environment block. `/proc/<pid>/environ` is readable only by the same user and by root, which is the exposure the caller's own environment already has.
- Exported shell functions are environment entries too: the function also runs `unset -f` on every name from `declare -Fx`.
- If an exported name cannot be unset (a readonly variable), the function prints that name and fails closed with exit 2; no command runs.
- The names left after the loop are the allow-list plus `ALFRED_ROLE`, `LANG` and `TMPDIR`. A shell also adds its own bookkeeping names (`PWD`, `OLDPWD`, `SHLVL`, `_`); the bats cases allow those four and nothing else.

The child's environment holds exactly these names:

| Name | Value |
|---|---|
| `HOME` | the caller's |
| `PATH` | the caller's (finds `claude`, `jq` and the hook tools) |
| `LANG` | `C.UTF-8` |
| `TMPDIR` | the caller's, or `/tmp` |
| `CLAUDE_CONFIG_DIR` | the caller's, only when set (it locates `.credentials.json`, the plugins and the catalog) |
| `ALFRED_ROLE` | `worker` |
| `CLAUDE_CODE_OAUTH_TOKEN` | the caller's, only when set: the fleet's fallback login (token mode, below). Never printed, never in argv |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE` | the caller's, only when set: network plumbing a devbox may need to reach the API. None is set on this devbox. Values are never printed |

Everything else is cleared. These names matter (the script's comment lists them, and the bats case in section 8 asserts each is absent from the child):

- **Gateway and platform credentials:** `LITELLM_API_KEY`, `AGENT_RUNS_TOKEN`, `AGENT_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_SOCKET`.
- **The parent session's identity:** `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_PID`, `CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_ATTENDED`.
- **Session behaviour:**
  - `CLAUDE_CODE_ENTRYPOINT`: the parent's is `cli`. It is cleared so that the child sets its own and is not taken for an interactive session (section 4.3).
  - `CLAUDE_EFFORT`: the parent's is `high`. Claude Code sets it in Bash children for information only. The voice's effort is set on purpose with `--effort` from `ecr-anthropic-effort` (section 5).
  - `CLAUDE_CODE_EFFORT_LEVEL`: it would override `--effort` (Claude Code docs: it "takes precedence over `--effort`"). Not set on this devbox.
  - `CLAUDE_CODE_ENABLE_TELEMETRY`, `AGENT_RUNS_OTLP_LOGS_ENDPOINT`.
- **Billing, endpoint and model:** every `ANTHROPIC_*` name, including `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` and `ANTHROPIC_DEFAULT_*_MODEL`. Also `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_FOUNDRY`. Each of these could silently switch billing, endpoint or the alias target.

**Settings files can still set the environment.** Claude Code applies the `env` block and `apiKeyHelper` of its settings files, which the allow-list cannot stop. Before the call, the script reads three files, each only when it is a regular file:

- `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`;
- `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.local.json`;
- `/etc/claude-code/managed-settings.json`.

If any of them has an `apiKeyHelper` key, or an `env` key named `ANTHROPIC_*` or `CLAUDE_CODE_USE_*`, the script exits 7 with `ERROR (credential source not allowed: <file> <key name>)`. An `env` key `CLAUDE_CODE_EFFORT_LEVEL` gives `note: effort overridden by <file> env CLAUDE_CODE_EFFORT_LEVEL` and the run goes on. The script never prints a value. On this devbox `settings.json` has no `env` and no `apiKeyHelper`, `settings.local.json` holds only `hooks`, and there is no managed file. The cwd is an empty temp directory, so no project settings apply.

**Two login modes.** The fleet logs in one of two ways, and a devbox can switch between them at a lead restart (`/usr/local/lib/alfred/start-helpers.sh` lines 93-180):

- **Full login** (`.credentials.json`, written by `claude auth login`). The lead runs with Remote Control. `start-helpers` starts the lead as `env -u CLAUDE_CODE_OAUTH_TOKEN claude ... --remote-control`, so the token is not in the lead's process and not in its Bash children. This devbox is in this mode: the token is present in PID 1's environment and absent from the lead `claude` process and from this shell (name-only checks). The login's refresh token expires about 30 days after the login and is not extended by use.
- **Token mode** (`CLAUDE_CODE_OAUTH_TOKEN`, from `claude setup-token`, inference-only). Used when the auth mode is `headless`, or when the full login is missing, has no expiry, or expires within an hour. The lead then runs with the token in its environment ("today's command (token auth)").

The script picks the mode from what it is given:

| Caller has `CLAUDE_CODE_OAUTH_TOKEN` | Mode | Pre-call requirement |
|---|---|---|
| yes | token | the token is passed to the child. The Claude Code docs say it "takes precedence over keychain-stored credentials" |
| no | full login | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json` is a regular file with a non-empty `claudeAiOauth.refreshToken` and a numeric `claudeAiOauth.refreshTokenExpiresAt` more than `CALL_TIMEOUT` + 60 s away. This is the rule of `start-helpers` `_full_login_state` with a margin that fits one voice call; the plugin cannot rely on the devbox image's script, so it carries the rule itself. Only the state word is printed (`ok`, `expired:<date>`, `noexpiry`, `missing`). Anything but `ok` gives exit 7: `ERROR (no login for the voice: full login <state>, no CLAUDE_CODE_OAUTH_TOKEN in the environment. Known cause: a token-mode devbox whose lead does not pass the token to its Bash tool (lead question L7), or an expired full login. Fix: renew the login with env -u CLAUDE_CODE_OAUTH_TOKEN claude auth login and restart the lead; for a token-mode devbox, a hub item to deliver the token as a mode-600 file)` |

**Does the token reach the script on a token-mode devbox?**

- No variable needs to reach the voice through Claude Code except this token, and Claude Code passes its own environment to Bash children unless `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` is set. Evidence on this devbox (names only): `LITELLM_API_KEY`, `AGENT_RUNS_TOKEN` and `AGENT_MESSAGING_TOKEN` reach this shell. The scrub is not set in the lead process.
- Claude Code does filter some names: the four `OTEL_*` names are in the lead process and absent from this shell. The docs give no rule that removes `CLAUDE_CODE_OAUTH_TOKEN` with the scrub off. Whether it reaches a Bash child on a token-mode devbox could not be checked here, because this devbox is in full-login mode.
- **If it does not reach the child,** option A has no login on that devbox. The script then exits 7 with the message above, and the voice is a visible non-responding voice, never a silent fallback. The fix would be outside this repo: the devbox image delivers the token as a mode-600 file, as it does for the GitHub tokens under `/var/run/secrets/`. That would be a hub item. Reading it from `/proc/1/environ` is rejected: it takes a secret out of another process, and the scrub's PID namespace would block it.
- **Check:** a name-only check on a token-mode devbox (`env | cut -d= -f1 | grep -cx CLAUDE_CODE_OAUTH_TOKEN` from a lead's Bash tool, for example the metis lead) settles it before the release. If no lead is in token mode, criterion 14 settles it only for the mode of the devbox it runs on. See lead question L7.

**Credential check before the call.** The script runs `run_child timeout 20 claude auth status --json`, so it gets the same environment and the same cwd as the call. This makes no model call. Required fields:

| Mode | `loggedIn` | `authMethod` | `apiProvider` |
|---|---|---|---|
| full login | `true` | `claude.ai` (seen here with the `run_child` pattern) | `firstParty` |
| token | `true` | `oauth_token` (seen here with the `run_child` pattern and a fake token exported inside the subshell) | `firstParty` |

- `auth status` does not validate a token: a fake token also gave `loggedIn: true`. So a dead token is caught only at the call, as exit 6 with the API status.
- A timeout, a non-zero exit, output that is not JSON, or any other value gives exit 7: `ERROR (credential check failed: <field>=<value or ->)` or `ERROR (credential check failed: auth status timed out after 20 s)`. Only the three field names, and values that match `^[A-Za-z0-9_.-]{1,32}$`, are printed.
- A mode mismatch also gives exit 7: a token was passed but the status reports `claude.ai`, or the reverse.

**Credential check after the call:**
- The script always prints one line, `credential: mode=<full|token> auth_method=<v> api_provider=<v> api_key_source=<v|-> provider=<v|->`, with values validated as above. Criterion 14, and the first ECR a lead runs in token mode, record the `api_key_source` value they saw on the issue.
- The init event's `apiKeySource` must be `none`, in both modes. `none` was seen here in full-login mode (P4). In token mode the token is an OAuth credential, not an API key, so `none` is the expected value there too. That is confirmed only by a real call in token mode: at criterion 14, if that devbox is in token mode, or by the first ECR a lead runs in token mode. Any other value (an API key from a user, project, org or temporary source) gives exit 7.
- Every `modelUsage` entry's `provider` must be `firstParty`.
- Otherwise the voice exits 7 and its content is not used: the voice ran on another credential, and the row says so.
- **Fix path if token mode reports another value.** Every token-mode ECR then exits 7, visibly, with the value in the `credential:` line. Nothing falls back.
  1. The lead records the value on the issue.
  2. The lead checks, against the Claude Code docs or SDK types, that it names the OAuth-token source and not an API-key source (`user`, `project`, `org`, `temporary`).
  3. A follow-up patch adds that one literal to the accepted set for token mode only, with a bats case, in a patch release.
  4. Until then, token-mode devboxes run the ECR with the Claude row as a visible `ERROR` (partial panel).

#### 4.3 The headless call and the hooks in the child

```
# rundir: mktemp -d "${TMPDIR:-/tmp}/ecr-anthropic.XXXXXX", mode 700, empty; removed by the EXIT trap
# run_child (section 4.2) clears the environment, exports ALFRED_ROLE and LANG, cds to rundir and execs
run_child timeout -k 5 "$CALL_TIMEOUT" claude -p \
  --model "$MODEL" --effort "$EFFORT" --output-format stream-json --verbose \
  --tools "" --strict-mcp-config --no-session-persistence \
  < "$rundir/prompt.txt" > "$rundir/out.jsonl" 2> "$rundir/err.txt"
```

- `prompt.txt` holds the reviewer wrapper that the Agent block carries today (verdict / up to three insights / conditions, "Do not explain your role", and the `---` fences), with the anonymized prompt inside, unchanged. The wrapper text moves from `SKILL.md` into the script. The prompt goes on stdin, so a large prompt is never argv and a variadic flag cannot swallow it.
- `--tools ""` and `--strict-mcp-config` together give `tools: []` and `mcp_servers: []` in the init event (P4). The voice cannot write, cannot message and cannot read the repo. The empty cwd keeps project `CLAUDE.md` files out.
- `--effort` is the value of `ecr-anthropic-effort` (section 5). The effort is set on purpose: the voice no longer inherits the lead's effort, and leaving it out would run the voice at the model's default, which is `medium` for Fable 5.2 in the catalog, below the lead's `high`. A settings `maxEffortLevel` cap still applies (Claude Code docs).
- The call never gets these flags:
  - `--fallback-model`;
  - `--max-budget-usd`: in P2 it did not stop the call ($0.0957 spent against a 0.05 budget), and it then threw the answer away (`result: null`);
  - `--bare`: it would drop the OAuth login;
  - `--dangerously-skip-permissions`;
  - `--system-prompt`: the default system prompt stays, as for today's sub-agent.
- `CALL_TIMEOUT` is a script constant, 590 s, as the resolver's `TOOL_CAP`, so the script prints `TIMEOUT` before the Bash tool's 600 s limit stops it.

**Hooks in the child.** The child loads the user's plugins, so the alfred-agent hooks run in it:

- **Gated by `ALFRED_ROLE=worker`:**
  - the Stop loop check (`bin/alfred-loop-check` lines 472 and 533);
  - the reply-time hooks (`lib/reply-time.sh`);
  - the work-item reminder on UserPromptSubmit (`bin/alfred-workitem` line 500).
- **Not gated (`bin/alfred-workitem` `cmd_hook`):**
  - On Stop (lines 503-505), an unmarked session gets a record in `deviations.jsonl`.
  - On SessionEnd (lines 507-521), a detached `check-session` starts. It does not message the hub when the entrypoint is not interactive (`suppress_reason`, `interactive_entrypoint` allows only `cli`, `claude-vscode` and `claude-desktop`). Because the allow-list clears the parent's `CLAUDE_CODE_ENTRYPOINT=cli`, the child is recorded as `suppressed:non-interactive` and sends nothing. With the parent's value inherited, every ECR would send the hub a `[deviation]` notice. The value that a cleared child sets for itself was not verified without a model call; the bats case only shows that the name is absent.
- **SessionStart context:** the child gets the SessionStart context (owner-communication, doctrine index, routed `all` and `worker` rules), as today's sub-agent gets the SubagentStart rules. That is the 4.7k tokens in P1 and P2.

**Token attribution (decided, L6 in section 13).**
- The child's tokens most likely never reach the work-item store at all, attributed or not:
  - Claude Code already keeps the four `OTEL_*` exporter names out of its Bash children (they are in the lead process and absent from this shell, name-only check).
  - The allow-list does not pass `CLAUDE_CODE_ENABLE_TELEMETRY`, `AGENT_RUNS_OTLP_LOGS_ENDPOINT` or `AGENT_RUNS_TOKEN`.
  - So the child has no exporter, and nothing about it is sent. Its session is also unmarked, so even a record would not be attributed.
- The voice prints one `usage:` line from the result event instead (input, output, cache-write and cache-read tokens of the child). The lead adds it to the item's report by hand when it matters.
- Attributing the tokens would mean passing the exporter variables and marking the child with the parent's work item. That changes `bin/alfred-workitem` and is not in this item's bounds.

#### 4.4 Served model

From `out.jsonl`, the script reads the distinct `.message.model` values of the `type == "assistant"` events and the keys of the result event's `modelUsage`. Each value is validated against `^[A-Za-z0-9._:-]{1,128}$`. Invalid values are counted (`note: served value invalid (<n>)`) and never printed.

- One served line carries both readings: `served=<v> source=response|usage|none usage_models=<k1>[,<k2>]|-`.
- `source=response` when exactly one valid assistant model exists, `source=usage` when there is none but exactly one valid `modelUsage` key, else `served=- source=none`.
- Two or more distinct values give `served=<a>,<b>` and `note: more than one model answered`. The catalog marks Fable 5.2 with `refusal_fallback`, so a mid-run switch is possible.
- When the requested value starts with `claude-` and differs from a reported served value, the line `note: served differs from requested (<req> -> <served>)` follows. For an alias override such as `fable`, the served ID is shown and not compared.
- The skill text says that both readings come from Claude Code's own output. `source=response` is the model field of the response as Claude Code reports it, and it may only repeat the request; it is not independent proof.

#### 4.5 Catalog detector

1. **Directory:** `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/model-catalog/`, glob `*-cc.json`.
2. **File checks first**, on every match. A file is a candidate when it is a regular file and not a symlink (`-f`, `! -L`), is owned by the user (`-O`), and is at most 256 KiB (the files here are 16 KB and 14 KB). Other files are skipped and counted.
3. **Too many files:** if there are more than 16 candidates (script constant `CATALOG_MAX_FILES`), nothing is read, and the note is `note: model catalog not read (too many files: <n>)`.
4. **Which file:**
   - Every candidate's `.fetchedAt` is read with jq. A candidate whose file is not JSON or whose `fetchedAt` is not an integer from 1e12 to 1e13 (epoch milliseconds) is skipped and counted.
   - The candidate with the highest `fetchedAt` is chosen, whatever its name. Only that file is read further. An older file (such as the October one that still lists `claude-fable-5-1`) is never mixed in, and is never used in place of a newer file that fails step 5.
5. **Shape of the chosen file:** `.version == 2`, `.catalog.surface == "cc"`, `.staleAt` an integer in the same range, and `.catalog.config.models` an array. Otherwise: `note: model catalog not read (unexpected shape)`.
6. **Staleness:**
   - If the chosen file is past its `staleAt`, it is still used, and its notes carry `(catalog stale, fetched <h>h ago)`. `staleAt` is about one hour after `fetchedAt`, so a fresh-only rule would silence the detector on most runs.
   - If it is older than 7 days (script constant `CATALOG_MAX_AGE_DAYS`), nothing is read: `note: model catalog not read (older than 7 days)`.
7. **Path:** `.catalog.config.models[] | select(.section == "main") | .id`. `runtime.family` is not used.
8. **ID check before echo:** the table regex (`^claude-[a-z0-9]+(-[a-z0-9]+)*$`, at most 64 characters, in jq with `\A...\z`). Failing IDs are counted, `note: catalog: <n> ids not shown (invalid characters)`, and never printed.
9. **Table, unranked list and output:**
   - The table wins over `ecr-anthropic-unranked`: an ID in both is treated as a table row, and the unranked entry is ignored for the run. `tests/thresholds.bats` refuses the overlap at the write boundary.
   - Each valid `main` ID that is neither a valid row of `ecr-anthropic-models` nor an entry of `ecr-anthropic-unranked` gives `note: not ranked: <id> (in the runtime model catalog, not in ecr-anthropic-models)`.
   - The `main` IDs that are silenced by the unranked list are printed once, on one line: `note: unranked by choice: <id>[ <id> ...]`. The line is left out when there are none.
10. **Failure:**
    - No directory, no candidate, or no candidate with a valid `fetchedAt` gives `note: model catalog not read (<absent|no valid file>)`.
    - When `ecr-anthropic-unranked` is missing or invalid, the detector treats it as empty and says `note: ecr-anthropic-unranked not configured`.
    - None of this changes the choice or the exit code.

#### 4.6 Output and exit codes

Output lines (stdout, in this order; `<p>` and `<X>` are canonical decimals built from integer micro-dollars, for example `40` or `2.5`):

```
ecr-anthropic-voice: source=resolved limit=<X> unit=output-usd-per-mtok rows=<n>
candidate=<id> rank=<k> price=<p> status=chosen|above-limit|not-needed
LEFT OUT: row <k> <id or "(invalid id)"> (<no price|invalid price|invalid id|duplicate id|not an object>)
SKIPPED: <id> (price <p> above limit <X>; more capable than the pick)
note: not ranked: <id> (...)            and the other detector notes (section 4.5)
voice=anthropic model=<id> origin=resolved|override price=<p>|- limit=<X>|- effort=<level>
credential: mode=<full|token> auth_method=<v> api_provider=<v> api_key_source=<v|-> provider=<v|->
served=<id>|- source=response|usage|none usage_models=<ids>|-
usage: input=<n> output=<n> cache_write=<n> cache_read=<n>
note: ...
<content> | ERROR (...) | TIMEOUT (>590s)
```

- Override mode prints `ecr-anthropic-voice: source=override limit=-`, no candidate lines and no detector notes, and `origin=override price=- limit=-`. It still reads `ecr-anthropic-effort`, and still runs the settings, login and `auth status` checks.
- `--resolve` stops after the `voice=` line and exits 0, 2, 3 or 4.
- A hostile value from a row is never echoed: an invalid ID shows as `(invalid id)`.

| Exit | Meaning | Voice in `N/V` | Skill action |
|---|---|---|---|
| 0 | answered; served equals requested (or alias override with a served ID reported) | responding | use the content |
| 1 | answered; served differs, more than one model, or served not reported | responding, row flagged (decided, L3) | use the content; the Step 4 row shows the `served=` value and the note |
| 2 | usage or environment error (arguments, `jq`/`claude`/`timeout`/`mktemp`/`env` missing, prompt file invalid) | non-responding | show the cause |
| 3 | resolution failed: a threshold missing or invalid, X invalid, table not a non-empty array, or no valid row | non-responding | show the cause; never edit a threshold for a run |
| 4 | no model at or under X | non-responding | show the `SKIPPED:` lines and `ERROR (no Claude model at or under the limit <X>)` |
| 5 | the runtime rejected the model | non-responding | `ERROR (model not accepted: <id>)` |
| 6 | the call failed: non-zero exit, `is_error`, no result event, empty result, or timeout | non-responding | `ERROR (claude failed: ...)` or `TIMEOUT (>590s)` |
| 7 | credential source not as expected or no login: a settings file, the login state, `auth status` (including its 20 s timeout) before the call, or `apiKeySource`/`provider` after it | non-responding; content not used | `ERROR (credential ...)` or `ERROR (no login for the voice: ...)`. Tell the lead, and name the known cause and its fix: an expired full login (renew with `claude auth login` and restart), a token-mode devbox whose token does not reach the Bash tool (lead question L7; fix: a hub item to deliver the token as a mode-600 file), or a token-mode `apiKeySource` other than `none` (the fix path in section 4.2) |

**Precedence** when more than one code applies:
- The checks run in this order and the first failure exits: 2 (arguments, tools, prompt file, run directory), 3 (thresholds and table), 4 (no model at or under X), 7 (settings, login state, `auth status`; all before the call).
- After the call, the order is 7 (`apiKeySource` / `provider`), then 5 (model rejected), then 6 (call failed or timed out), then 1 (served check), then 0. So 7 wins over 5, 6 and 1: a wrong credential is reported even when the call also failed or was served by another model.
- `--resolve` stops after step 4 and can exit 0, 2, 3 or 4.

- On every exit from 2 to 7 there is no second call and no other model.
- The script makes at most one model call (`claude -p`) per invocation. It also makes one `claude auth status --json`, which makes no model call.

### 5. Thresholds

| Name | Type | Validation | Value |
|---|---|---|---|
| `ecr-anthropic-max-output-usd-per-mtok` (X) | JSON number | the file value is a number; its text matches `^[0-9]{1,6}(\.[0-9]{1,6})?$` and is above zero. This refuses a string, negative, zero, exponent form, more than six decimals and anything of a million or more | No script default. The owner sets the value; see section 12 for what blocks |
| `ecr-anthropic-models` | JSON array of 1 to 32 objects `{"id": string, "output-usd-per-mtok": number}`, most capable first | Not an array, empty or over 32 rows: exit 3. Per row: `id` matches `^claude-[a-z0-9]+(-[a-z0-9]+)*$` and is at most 64 characters (checked in jq with `\A...\z`, so an embedded newline fails); unique; price as for X. A failing row is `LEFT OUT` and named (decided, L5) | Decided (L2): `claude-fable-5-2` 40, `claude-opus-5-5` 20, `claude-sonnet-5-5` 10 (list output prices on the Anthropic pricing page) |
| `ecr-anthropic-unranked` | JSON array of 0 to 64 ID strings | each matches the table ID regex and is unique; `tests/thresholds.bats` refuses an ID that is also in `ecr-anthropic-models`. At run time an invalid entry is ignored and counted in a note, and on an overlap the table wins (section 4.5) | `["claude-haiku-5-5", "claude-fable-5-1"]`: Haiku is left out by L2, and Fable 5.1 by the owner. Without this list, the newest catalog's `main` section (which holds `claude-haiku-5-5`) would warn on every run |

| `ecr-anthropic-effort` | JSON string | one of `low`, `medium`, `high`, `xhigh`, `max` (the `--effort` choices of Claude Code 2.1.317). Anything else: exit 3, `threshold invalid: ecr-anthropic-effort`. A level the chosen model does not support is expected to be a runtime rejection (exit 6). **Not verified:** that needs a model call. Claude Code reports no effort field to check it against: there is none in the P1 result keys or the P4 init keys, only `per_turn_effort_active`. So the script prints the effort it requested (`effort=<v>` on the `voice=` line), and the served effort is not checked | `high`: the effort the lead runs at today (`CLAUDE_EFFORT=high` in this shell) and the issue's no-downgrade intent. The script holds no default; the file holds `high` |

- **Choice rule:** walk the valid rows in order and take the first with price at or under X (integer micro-dollar compare, so a price equal to X is eligible). Each earlier valid row is `SKIPPED` and `above-limit`. Each later one is `not-needed`.
- **Override:** `ALFRED_THRESHOLDS` can point a run at another file.
- **Expected result with the decided table:** X at 40 or more gives `claude-fable-5-2`. X from 20 up to 40 gives `claude-opus-5-5`, with `SKIPPED: claude-fable-5-2`. X from 10 up to 20 gives `claude-sonnet-5-5`. X under 10 gives exit 4, "no model".

### 6. Failure table

Criterion 6 ("a source cannot be reached, returns no usable value, or returns a value that fails validation") applies to the threshold table and X, the sources that choose the model. The catalog is not such a source: its failures (rows 9 and 10) are notes only and never make the voice non-responding.

| # | Failure | Detected by | Output | Exit | `claude -p` called |
|---|---|---|---|---|---|
| 1 | bad arguments, hostile `--model` | argument parse, regex | usage / `invalid model id` | 2 | no |
| 2 | prompt file missing, a symlink, empty, over 4 MiB | file checks | `prompt file invalid` | 2 | no |
| 3 | `claude`, `jq`, `timeout`, `env` or `mktemp` missing | `command -v` | `<tool> not found` | 2 | no |
| 4 | X or the table name unknown, or the file missing or malformed | `alfred-config` exit 2 | `threshold not configured: <name>` | 3 | no |
| 5 | X has the wrong type or range | regex, jq type | `price limit invalid: <name>` | 3 | no |
| 6 | table not an array, empty, over 32 rows | jq | `model table invalid: <name>` | 3 | no |
| 7 | a row is invalid (not an object, bad or duplicate ID, no or bad price) | jq per row | `LEFT OUT: row <k> ...`; the run goes on. If no valid row is left: `ERROR (no valid row in ecr-anthropic-models)` | 3 only when no valid row is left | as resolved; no when exit 3 |
| 8 | every valid row is above X | compare | `SKIPPED:` lines + `ERROR (no Claude model at or under the limit <X>)` | 4 | no |
| 9 | catalog absent, no valid file (symlink, not owned, over 256 KiB, bad JSON, wrong version or surface, bad epochs), or older than 7 days | detector | `note: model catalog not read (...)` | no effect | as resolved |
| 10 | a catalog `main` model is in neither the table nor the unranked list | detector | `note: not ranked: <id>` (marked stale when past `staleAt`) | no effect | as resolved |
| 11 | the runtime rejects the model | result event `is_error` with `api_error_status` 404 (P3) | `ERROR (model not accepted: <id>)` | 5 | once |
| 12 | `claude` exits non-zero, `is_error` with another status (429 usage limit, 5xx), or no result event | exit code, result event | `ERROR (claude failed: exit <rc>[, <subtype>][, HTTP <status>])` + at most 3 stderr lines, each at most 200 characters with control characters removed | 6 | once |
| 13 | timeout | `timeout` exit 124 or 137 | `TIMEOUT (>590s)` | 6 | once |
| 14 | empty result text | jq | `ERROR (empty response)` | 6 | once |
| 15 | served differs from requested | served check | `served=<v> source=response ...` + `note: served differs ...` | 1 | once |
| 16 | served not reported, or the value is invalid | served check | `served=- source=none` (+ `note: served value invalid`) | 1 | once |
| 17 | more than one model answered | served check | `served=<a>,<b>` + note | 1 | once |
| 18 | `mktemp` fails, or the run directory cannot be written | checks | `mktemp failed` | 2 | no |
| 19 | a settings file holds `apiKeyHelper` or an `ANTHROPIC_*` / `CLAUDE_CODE_USE_*` env key | settings pre-check | `ERROR (credential source not allowed: <file> <key name>)` | 7 | no |
| 20 | `claude auth status --json` returns a value outside section 4.2 (not `loggedIn: true`, an `authMethod` that does not match the mode, not `apiProvider: firstParty`) | pre-call check | `ERROR (credential check failed: <field>=<value or ->)` | 7 | no |
| 20a | `claude auth status --json` times out (`timeout 20`), exits non-zero, or prints something that is not JSON | pre-call check | `ERROR (credential check failed: auth status timed out after 20 s)` or `... auth status exit <rc>` or `... auth status output not JSON` | 7 | no |
| 20b | no token in the environment, and the full login is `missing`, `noexpiry` or `expired:<date>` (or expires within the call time plus 60 s) | login-state check (section 4.2) | `ERROR (no login for the voice: ...)` with the known cause and its fix (section 4.2: renew the login, or L7 and a hub item for a token file) | 7 | no |
| 20c | `ecr-anthropic-effort` missing or not one of the five levels | threshold check | `threshold invalid: ecr-anthropic-effort` | 3 | no |
| 21 | init `apiKeySource` is not `none`, or a `modelUsage` `provider` is not `firstParty` | post-call check | `ERROR (credential source not as expected: ...)`; content not shown | 7 | once |

The EXIT trap removes the run directory on every path.

### 7. How the skill uses it

- **Step 3a:** unchanged for the gateway.
- **Step 3b:**
  - "Fire all four queries simultaneously: one Bash call per `voice=` line of the resolver, and one Bash call `${CLAUDE_PLUGIN_ROOT}/bin/ecr-anthropic-voice --prompt /tmp/ecr-prompt.txt`, each with `timeout: 600000` or in the background."
  - The words "in parallel" stay in Step 3.
  - The exit table from section 4.6 goes in the skill.
  - The repeat-call sentence is limited to the gateway voices (section 3, line 111).
- **Override:** a request that names a Claude model or alias passes it as `--model <id>`. It is used as given, marked `override` and not held to X.
- **Rules:** "The Claude voice never runs on the session model and never falls back to another model."
- **Served-check caveat:** the `served=` value and `usage_models=` both come from Claude Code's own output. `source=response` may only repeat the request.
- **Step 4 row (placeholders only):** `| Claude voice | Anthropic (headless) | <requested> -> <served> | <source>, limit <limit>, price <price> | ... | ... |`. Source is `resolved` or `override`. This design never produces the issue's third source value, `default`, because no default model exists (no silent fallback).
- **Partial panel:** exits 2 to 7 make the row `ERROR`/`TIMEOUT` and count as non-responding in `N/V voices`. Exit 1 keeps the content and shows the served note in the row.

### 8. Tests

Runner: bats (CI job `bats`), plus CI `shellcheck bin/* hooks/*.sh tests/stub/*` (0.9.0, no `-x`).

Style: behaviour tests with:
- `tests/stub/claude` first on `PATH`;
- `ALFRED_THRESHOLDS` pointing at a fixture file;
- `CLAUDE_CONFIG_DIR` and `HOME` pointing at a fixture directory holding the catalog files and settings files;
- `TMPDIR` under `BATS_TEST_TMPDIR`.

There is no sleep or load, and no real model call (section 13): the timeout case uses a stub that exits 124.

**Code-review plan.** The code reviewer applies R3-B1 as an explicit adversarial lens. It reads every line of `bin/ecr-anthropic-voice` and the new stubs that starts a process or builds a command, and asks whether a secret can reach one of these:
- an argv (`/proc/<pid>/cmdline`);
- a `NAME=value` env prefix or an `env NAME=value` call;
- `set -x` output, an error message or a log;
- a `/proc` read.

Any secret in argv, in an env prefix or in `/proc` is CRITICAL and blocks the merge. That includes `CLAUDE_CODE_OAUTH_TOKEN`, a proxy URL with credentials, and any value from `.credentials.json`.

`tests/stub/claude`:
- **On `auth status --json`:** prints `$STUB_DIR/auth.json` (default: `loggedIn` true, `claude.ai`, `firstParty`) and exits with `${STUB_AUTH_EXIT:-0}`.
- **On `-p`:**
  - appends one `ARGV:` line with each argument bracketed (as `tests/stub/curl-argv` does) to `$CLAUDE_ARGV_LOG`;
  - writes the names (not values) of its environment, from `env`, sorted, to `$STUB_DIR/env.names`;
  - records `pwd`, the directory listing and stdin to files under `$STUB_DIR`;
  - prints `$STUB_DIR/claude.jsonl` and exits with `${STUB_CLAUDE_EXIT:-0}`.

Fixtures may name concrete IDs.

| AC | Check | File |
|---|---|---|
| 1 | Two tables in turn (set A, set B, different first rows): the recorded `--model` follows the table. Text: no `claude-` and no digit after a family name in `SKILL.md` (existing test 9, kept); no `Agent(` block and no `model:` line in `SKILL.md` | `tests/ecr-anthropic-voice.bats`, `tests/ecr-template.bats` |
| 2 | Fixture of 5 rows: a newest row first priced 90, a row priced 40, a row 20, a row 2.5, plus one more below. X at 40: the 40 row is chosen (at-X eligible), the 90 row is `SKIPPED` and named. X at 25: the 20 row, with two `SKIPPED`. X at 90: the newest | `tests/ecr-anthropic-voice.bats` |
| 3 | One case each: a row with no price is `LEFT OUT` by ID; a catalog `main` ID not in the table gives `note: not ranked`; the same ID listed in `ecr-anthropic-unranked` gives no note; every row above X gives exit 4, the ERROR line and no `-p` call | same |
| 4 | The `ARGV:` log has exactly one `-p` line, and its `--model` value equals the resolved ID. "Called once per run" counts model calls (`-p`); the one `auth status --json` call is not counted. The lead confirmed this reading | same |
| 5 | A stub stream whose assistant model differs gives `served=<other>`, the differs note and exit 1. A stream with no model field and empty `modelUsage` gives `served=- source=none usage_models=-` and exit 1. Two models give the more-than-one note. The `usage_models=` value equals the fixture's `modelUsage` keys | same |
| 6 | One case per failure-table row 3 to 8, 11 to 14 and 18 to 21: the named cause, the exit code, at most one `-p` call, never a second call with another ID, and the run directory gone. Row 2: one case each for a missing file, a symlink, an empty file and a file of 4 MiB + 1 byte (exit 2, no call), and a file of exactly 4 MiB that passes. Row 7 with no valid row: a table whose every row is invalid gives exit 3, `ERROR (no valid row ...)`, and no call | same |
| 6 (catalog, row 9 and 10) | No `model-catalog` directory, a symlinked file, a file not owned by the user (skipped when the test runs as root), a file over 256 KiB, bad JSON and `version: 1`: each gives `note: model catalog not read`, the same choice and the same exit as with no catalog. **Two files:** an older file listing `claude-old-1-1` in `main` and a newer one listing `claude-new-2-2`: only `claude-new-2-2` is named. **Stale file:** `fetchedAt` 3 hours ago and `staleAt` 2 hours ago gives the note marked `(catalog stale, fetched 3h ago)`; `fetchedAt` 8 days ago gives `not read (older than 7 days)`. **Pick by `fetchedAt`, not by name:** a newer file whose name sorts first is the one read. **Too many files:** 17 candidate files give `not read (too many files: 17)` and no `not ranked` note even when one file lists an unranked ID. **Newest file with a bad shape:** the note says `unexpected shape`, and the older valid file is not used in its place. **Unranked:** a `main` ID in `ecr-anthropic-unranked` gives `note: unranked by choice: <id>` once and no `not ranked` note; an ID in both the table and the unranked list is a candidate. An ID with a metacharacter in the catalog is counted and not printed | same |
| 7 | Hostile X (`"40"` string, -1, 0, `abc`, 1e12, 0.0000001, null) gives exit 3 and no call. Hostile row IDs (`claude-x;id`, `-claude-x`, `$(id)`, empty, 65 characters, uppercase, embedded newline) and prices are `LEFT OUT` without echoing the raw value, with no call carrying them. Hostile `--model` gives exit 2 | same |
| 8 | Recorded argv has `-p`, an empty argument after `--tools`, `--strict-mcp-config` and `--no-session-persistence`, and none of `--fallback-model`, `--max-budget-usd`, `--bare`, `--dangerously-skip-permissions` or `bypassPermissions`. Stdin contains the prompt file's bytes unchanged inside the wrapper. The stub's cwd is an empty directory under `TMPDIR`. **Environment:** the test exports fake values for every denied name in section 4.2 (`LITELLM_API_KEY`, `AGENT_RUNS_TOKEN`, `AGENT_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_EFFORT`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_FABLE_MODEL`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_OAUTH_TOKEN`, ...). `env.names` holds only names from the allow-list of section 4.2 (with `ALFRED_ROLE`, `LANG` and `TMPDIR`) and the shell's own `PWD`, `OLDPWD`, `SHLVL` and `_`, and `ALFRED_ROLE` is present. Without `CLAUDE_CODE_OAUTH_TOKEN` in the caller, it is absent from `env.names` too. No fake value appears in argv, output or the run directory. Argv has `--effort` with the threshold's value; a second fixture with `ecr-anthropic-effort` `max` shows `--effort max`. **Both login modes:**
- *Full login:* no token in the caller, a fixture `.credentials.json` with an expiry 30 days ahead, and `auth.json` with `claude.ai`: the call runs.
- *Token mode:* a fake `CLAUDE_CODE_OAUTH_TOKEN` in the caller, no `.credentials.json`, and `auth.json` with `oauth_token`: the call runs, `env.names` has `CLAUDE_CODE_OAUTH_TOKEN`, and the fake value is in no argv, output or run-directory file.
- *Mismatches:* each gives exit 7 and no `-p` call. Token mode with `auth.json` reporting `claude.ai`; full-login mode with an expired, a `noexpiry` and a missing `.credentials.json`; `auth status` exiting 1, printing non-JSON, or exiting 124 (timeout). Text: Step 3 says "in parallel" | `tests/ecr-anthropic-voice.bats`, `tests/ecr-template.bats` |
| 8, 12 (no secret in argv, R3-B1) | **Stubs:** `tests/stub/timeout` and `tests/stub/env`, in the style of `tests/stub/curl-argv`, sit first on `PATH`.
- Each appends its full argv as one `ARGV:` line, with each argument bracketed, to `$EXEC_ARGV_LOG`, and the sorted names (not values) of its environment to `$EXEC_ENV_LOG`.
- The `timeout` stub then drops its own options and duration and execs the rest (the `claude` stub). The `env` stub only records, so any use of `env` shows in the log.

**Run:** the test exports a fake `CLAUDE_CODE_OAUTH_TOKEN` and a fake `HTTPS_PROXY` with a `user:password@` part, then runs `--prompt` mode, which calls `auth status` and `-p`. Assertions:
- neither fake value occurs in any `ARGV:` line of `timeout`, `env` or `claude` (`grep -F` on the logs), nor in stdout, stderr or any file left in `TMPDIR`;
- both names occur in the `timeout` and `claude` environment logs;
- the `env` log is empty: the script never calls `env`;
- `timeout` was called exactly twice: once with `20` before `claude auth status --json`, and once with `-k 5` before `claude -p`.

The same case runs in `--model` override mode | `tests/ecr-anthropic-voice.bats`, `tests/stub/timeout`, `tests/stub/env` |
| 9 | Template grep: the Step 4 Claude row has `<requested> -> <served>`, `<source>` and `limit <limit>`; the existing test 8 (header, `DROPPED` row, `alias -> served`) is kept | `tests/ecr-template.bats` |
| 10 | `--model fable` with a broken table: argv has `--model fable`, `origin=override limit=-`, exit 0, and no threshold error. `--model claude-big-9-9`, priced above X in the table, is still used | `tests/ecr-anthropic-voice.bats` |
| 11 | **`tests/ecr-template.bats`:** test "9 the Agent example ... opus" is replaced by "the Claude voice is the script call; no Agent block". Test 16 checks the new row for no digits. Test "the skill says it never substitutes ..." changes its `ERROR (model alias not accepted: <alias>)` string to the new text. Test "17 20 25" changes `The Claude sub-agent is not counted` to the new wording. **`tests/ecr-models-check.bats`:** version 2.45.0, and the previous-version grep becomes `2\.44\.0`. **`tests/thresholds.bats`:** the four names resolve; the effort is one of the five levels; X is a number in range; every table row and unranked entry passes the same rules as the script (the write boundary, doctrine 13); IDs are unique and the two lists do not overlap; the README names all four. The whole suite passes | `tests/ecr-template.bats`, `tests/ecr-models-check.bats`, `tests/thresholds.bats` |
| 12 | Applies to the token only. The script adds no new credential, but it passes the caller's `CLAUDE_CODE_OAUTH_TOKEN` to the child, through the environment only. From `.credentials.json` it reads only `refreshToken` presence and `refreshTokenExpiresAt`, and prints only the state word. Check: the token-mode case of AC 8. The fake token is in no argv line, no output and no file left after the run. The run directory is gone on success and on failure | `tests/ecr-anthropic-voice.bats` |
| 13 | The CI shellcheck job covers `bin/ecr-anthropic-voice` and `tests/stub/claude` through its globs. Not run locally: `shellcheck` is not installed on this devbox | `.github/workflows/shellcheck.yml` |
| 14 | Manual, after release, catalog bump, canary and cold restart: one real ECR. Paste the script's lines (`ecr-anthropic-voice --resolve` output plus the run's `voice=`, `served=` and `usage:` lines) and the Step 4 row on the issue. The lead names the expected ID from X and the table before the run. It waits on the value of X (section 12) | issue comment |

### 9. Measurable effect, and the chain for a new model

- In a real ECR, the Step 4 Claude row shows `claude-fable-5-2 -> claude-fable-5-2` when X is 40 or more. The run output lists the candidates, prices and X.
- **A new Claude model** (for example a Fable after 5.2) reaches ECR through this chain:
  1. Until step 7, every ECR on a devbox whose catalog lists the model in `main` prints `note: not ranked: <id>`.
  2. The lead adds one row to `config/thresholds.json` in its place and with its list output price (or adds the ID to `ecr-anthropic-unranked`). PR and review in this repo.
  3. Plugin minor release.
  4. Pin bump in `alfred-cc-tools` `marketplace.json`.
  5. Pin-bump canary on the lead's devbox.
  6. Devbox cold restart (the `install-alfred-plugin` init container installs the new version).
  7. The next ECR uses the new model if it is first at or under X.

  No `SKILL.md` edit is needed. This is the issue's "one-line threshold change" plus the release chain every plugin change already takes.
- **Config-delivery path.** The issue names a path that changes thresholds without a plugin release.
  - What exists: `ALFRED_THRESHOLDS` (read by `alfred-config` and the resolver) can point at a file outside the plugin, for example one mounted from GitOps.
  - Why it is not proposed: the variable replaces the whole thresholds file, not one key, and that file would then be owned by GitOps (the hub) and not by this repo. A per-key overlay would be a change to `alfred-config` that every threshold reader shares.
  - Status: neither is in this item's bounds. They are recorded as a possible follow-up item, not as part of this design.

### 10. Owner triggers (listed, not resolved)

- **No precedent, with real alternatives:** candidate source (C1, C3, C4), ranking (R1, R3) and price source (P1, P2) each have more than one real option. The voice-run question has only one viable option (A); that holds only if the reviewer accepts that B and B2 are not real alternatives.
- **Additional spending:** the Claude voice is outside the ECR cost cap. With A on a subscription login (full login or the setup token, `apiKeySource: none`, `provider: firstParty`, enforced by exit 7), no per-token USD is added. The voice's tokens most likely do not reach the work-item store at all (section 4.3, L6), so its use of the shared subscription shows only in its own `usage:` line, not in the item's totals. But moving the voice from Opus 5.5 to Fable 5.2 uses the shared subscription faster: the catalog notice reads "Fable is the most capable model and draws down usage much faster than Opus". If C1 were chosen, it would add an Anthropic API key with per-token billing.
- **Change to an accepted ADR or the target architecture:** none found in this repo (no `docs/adr/`). Platform ADRs were not in the brief, so this is not verified.
- **Objective 2 escalation triggers, reservations in an objective or ADR:** not checked, because the objective and ADR texts were not available to the designer.
- **ECR after design review:** not triggered (class medium).

### 11. State checks

- checked: the skill runs the Claude voice as an Agent sub-agent with `model: "opus"` | `skills/ecr/SKILL.md` lines 13, 31-45, 220-239, 262 | true
- checked: the `SKILL.md` lines that name the sub-agent or `opus` | `grep -n "sub-agent\|Agent tool\|opus" skills/ecr/SKILL.md` | lines 13, 31, 33, 35, 37, 39, 45, 47, 107, 111, 220, 224, 239, 262, 327; plus 8 (`allowed-tools`), 109 (override) and 271 (Source)
- checked: plugin version 2.44.0 and its pin | `.claude-plugin/plugin.json`; `tests/ecr-models-check.bats:146-147` | true
- checked: tests 9 (opus Agent line) and 16 (no version in the Step 4 row) exist; test 9 "no claude- string" also exists | `tests/ecr-template.bats:102-120` | true
- checked: `ecr-run-cost-cap-usd` is 1 and the resolver does not count the Claude voice | `config/thresholds.json`; `bin/ecr-panel-resolve` report line "(Claude voice not counted)" | true
- checked: the gateway key offers no Anthropic model | `bin/ecr-panel-resolve --list-offered` | 21 IDs: openai 9, gemini 8, fireworks_ai 4; 0 match `anthropic` or `claude`
- checked: the caller's environment holds platform secrets and session variables | `env` names only | `LITELLM_API_KEY`, `AGENT_RUNS_TOKEN`, `AGENT_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_CODE_ENTRYPOINT` (`cli`), `CLAUDE_EFFORT` (`high`), `CLAUDE_CODE_ENABLE_TELEMETRY`, `AGENT_RUNS_OTLP_LOGS_ENDPOINT`; no `ANTHROPIC_*`, no proxy variables
- checked: the devbox credential is a claude.ai OAuth subscription, no API key | key names and non-secret fields of `~/.claude/.credentials.json` (`subscriptionType: max`); init event `apiKeySource: none` | true
- checked: `claude` finds its login under the allow-list, without a model call | a bash subshell that unsets every exported name outside the allow-list (loop over `compgen -e`), exports `ALFRED_ROLE=worker LANG=C.UTF-8`, then `exec timeout 20 claude auth status --json` (the `run_child` pattern; re-run in round 4, replacing the round 2 `env -i` form) | `loggedIn: true`, `authMethod: "claude.ai"`, `apiProvider: "firstParty"`, `subscriptionType: "max"` (identity fields not printed)
- checked: settings files set no credential or env | `jq keys` on `~/.claude/settings.json` and `settings.local.json`; `ls /etc/claude-code` | `settings.json`: no `env`, no `apiKeyHelper` (`model: "opus"`); `settings.local.json`: only `hooks`; no managed directory
- checked: `--bare` cannot use OAuth | `claude --help` ("OAuth and keychain are never read") | true
- checked: headless flags exist | `claude --help`, Claude Code 2.1.317 | `--model`, `--output-format`, `--tools`, `--strict-mcp-config`, `--no-session-persistence`, `--max-budget-usd`, `--fallback-model`, `auth status --json`
- checked: an exact ID works headless | probe P1 | `modelUsage` key and `canonicalModel` `claude-fable-5-2`, `provider: firstParty`
- checked: the `fable` alias lags | probe P2 (headless `--model fable`) | served `claude-fable-5-1`
- checked: the stream reports a model per assistant message | probe P4 | `.message.model` = `claude-haiku-5-5`; init `tools: []`, `mcp_servers: []`, `apiKeySource: none`
- checked: an unknown model is rejected visibly | probe P3 | exit 1, `is_error: true`, `api_error_status: 404`, `modelUsage` empty, cost 0
- checked: `--max-budget-usd` does not prevent the spend and drops the answer | probe P2 | cost 0.09566 against 0.05; `subtype: error_max_budget_usd`, `result: null`
- checked: Claude Code's own price for Fable 5.2 is not reliable | probe P1 stderr and `costBasis` | `[claude-code:unrecognized_model]`, `costBasis: "unknown"`
- checked: the models list has no price and no capability order | Anthropic API reference, List Models | fields: `id`, `capabilities` (feature support), `created_at`, `display_name`, `lifecycle`, `line`, `max_input_tokens`, `max_tokens`; "do not infer a line from the `id`"
- checked: list prices | Anthropic pricing page | output per MTok: Fable 5.2 $40, Fable 5.1 $50, Opus 5.5 $20, Opus 4.5 $25, Opus 4.1 $75, Sonnet 5.5 $10, Haiku 5.5 $0.50 / $2.50 (tiered); Mythos 5.2 $40 (limited availability)
- checked: Anthropic IDs are not regular enough to parse | catalog cache | `claude-haiku-4-5-20251001`, `claude-sonnet-5`, `claude-opus-4-8` side by side
- checked: the catalog has two files | `stat`, `jq` on `~/.claude/cache/model-catalog/*.json` | `<uuid>-cc.json`: owner `dev-agent`, mode 600, 16036 bytes, fetched at the start of this session, keys `catalog, fetchedAt, staleAt, version`, `main`: `claude-opus-5-5`, `claude-fable-5-2`, `claude-sonnet-5-5`, `claude-haiku-5-5`. `tok-<hash>-cc.json`: 14462 bytes, 19 days older, past `staleAt`, extra keys `organizationUuid`, `resolution`, `main` holds `claude-fable-5-1` in place of 5.2. In both, `staleAt` is about one hour after `fetchedAt`
- checked: the catalog's alias target is ahead of the CLI | `.catalog.config.provider_alias_targets.fable.default` | `claude-fable-5-2`, while the CLI served 5.1 for `fable` (P2)
- checked: `ALFRED_ROLE=worker` silences the loop-check, reply-time and reminder hooks | `bin/alfred-loop-check:472,533`; `lib/reply-time.sh:93,129`; `bin/alfred-workitem:500` | true
- checked: the work-item Stop and SessionEnd hooks are not gated by `ALFRED_ROLE` | `bin/alfred-workitem:481-527` (Stop: `record_deviation`; SessionEnd: detached `check-session`), `555-590` (`suppress_reason` returns `non-interactive` for an entrypoint outside `cli|claude-vscode|claude-desktop`) | true
- checked: the plugin's agent files use aliases only | `grep -h '^model:' agents/*.md` | `haiku` 1, `opus` 2, `sonnet` 8
- checked: headless fast mode is off | P1 result `fast_mode_state: off` (`sdk_opt_in_required`) | true
- checked: LiteLLM public price map for `claude-fable-5-2` | WebFetch of the raw file | 3.5 MB; no such key in the first 100k characters (rest not read)
- checked: no ADR or baseline doc covers the ECR | `ls docs/` | only `docs/baseline/reply-time-line.md`

- checked: the Agent tool takes only aliases, and agent-file frontmatter `model` takes a full ID | Claude Code docs, sub-agents | "On an Agent tool call, that parameter takes a model alias: `sonnet`, `opus`, `haiku`, or `fable`. Claude can't pass a full model ID"; frontmatter: "a full model ID such as `claude-opus-5-5`". Both items from round 2's unverified list are closed. B2 stays dismissed under criterion 1 (fixed at release)
- checked: the token's place in the two login modes | `/usr/local/lib/alfred/start-helpers.sh` lines 93-180 (read, no value printed); `/proc/1/environ` and `/proc/$CLAUDE_PID/environ` names only | rc + full login starts the lead with `env -u CLAUDE_CODE_OAUTH_TOKEN`; token mode keeps it. Here: auth mode `rc`, token present in PID 1, absent from the lead `claude` process and this shell
- checked: what `auth status` reports in token mode | the same `run_child` subshell with a fake `CLAUDE_CODE_OAUTH_TOKEN` exported inside it before `exec timeout 20 claude auth status --json`. Round 4 re-run; the round 3 run put the fake value in `env`'s argv, which is harmless for a fake value and is the pattern R3-B1 removes | `loggedIn: true`, `authMethod: "oauth_token"`, `apiProvider: "firstParty"`, no `subscriptionType`. A fake token is not validated
- checked: Claude Code passes credentials to Bash children unless the scrub is set | Claude Code docs, env vars (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB`); names in the lead process and this shell | the scrub is not set; `LITELLM_API_KEY`, `AGENT_RUNS_TOKEN` and `AGENT_MESSAGING_TOKEN` pass; the four `OTEL_*` names do not
- checked: `--effort` exists and an env variable overrides it | `claude --help` (`low, medium, high, xhigh, max`); Claude Code docs (`CLAUDE_CODE_EFFORT_LEVEL` "takes precedence over `--effort`") | true; `CLAUDE_CODE_EFFORT_LEVEL` is not set here

**Claims not verified:**
- Whether `CLAUDE_CODE_OAUTH_TOKEN` reaches a Bash child on a token-mode devbox. This devbox is in full-login mode, so the token is not in its lead process. To be settled by a name-only check on a token-mode lead (L7), or at criterion 14 for the mode of that devbox.
- The init event's `apiKeySource` in token mode. Expected `none`; this needs a model call, so it is confirmed only by the first real call in token mode (criterion 14, or the first token-mode ECR).
- `ANTHROPIC_DEFAULT_FABLE_MODEL=claude-fable-5-2 claude -p --model fable` serves 5.2 (from the issue). Not re-probed: no model calls (section 13).
- `.message.model` in stream-json is the API's response field and not an echo of the request. The skill now says so (section 4.4).
- The entrypoint value the child sets for itself when `CLAUDE_CODE_ENTRYPOINT` is cleared, and that `check-session` then records it as `non-interactive`. Checking this needs a model call.
- That `claude auth status --json` reports a settings-file `apiKeyHelper` or an `env` key as a different `authMethod`. The settings pre-check covers that case directly.
- Whether a headless run refreshes the catalog cache, and how stable its format is.
- The LiteLLM price map beyond its first 100k characters.
- `shellcheck` was not run (not installed here).

### 12. Open questions

For the owner:

**O1. X: value and unit.**
- Options: USD per million output tokens; input tokens; a blend.
- Recommendation: output tokens at list price, as named in section 5. X at 40 or more gives Fable 5.2 today; from 20 up to 40 gives Opus 5.5; under 10 gives no Claude voice.
- **Blocks the build: yes, both value and unit.**
  - The value: the script has no default, and the shipped `config/thresholds.json` needs it.
  - The unit: it names the threshold (`ecr-anthropic-max-output-usd-per-mtok`) and the table field (`output-usd-per-mtok`); another unit renames both in the script, config, README and tests.
- If still unanswered: the builder may write the script and tests against fixtures with the recommended unit, but the PR does not merge and nothing is released until the owner gives the value and unit.

**O2. Price basis under the subscription.**
- The fleet pays a Max subscription, not per token, so X compares list prices as a measure of how fast the voice uses the subscription.
- Options: list price (recommended: public, stable and checkable); no price limit at all.
- **Blocks the build: only through O1.** "No price limit" removes X: the threshold, the `SKIPPED` path, exit 4 and the criterion 2 tests go, and the rule becomes "first valid row".
- If still unanswered: an O1 answer that gives a value in USD per MTok implies list price, and the build goes ahead on that.

**O3. Mythos.**
- Claude Mythos 5.2 (limited availability) has the same list price as Fable 5.2 and is not in this account's catalog.
- Options: leave it out of the table until the account has it, then the owner ranks it (recommended); rank it now.
- **Blocks the build: no.** If still unanswered: Mythos is not in the table. If a catalog ever lists it in `main`, the detector names it.

**O4. Anthropic API key (C1).**
- Only if the owner wants live discovery from the API.
- Recommendation: no. It adds a credential and per-token billing for data the table gives.
- **Blocks the build: no.** If still unanswered: no API key, no C1. The allow-list clears `ANTHROPIC_API_KEY`, and exit 7 refuses any API-key credential.

**Criterion 14 waits on X** (O1), as well as on the release, the catalog bump, the canary and the cold restart.

For the lead: L1 to L6 are decided in section 13. One new point:
- **L7. Token-mode check.**
  - Options: ask a lead that runs in token mode (the hub said the metis lead fell back to it) to run `env | cut -d= -f1 | grep -cx CLAUDE_CODE_OAUTH_TOKEN` in its Bash tool before the release (recommended: one name-only command settles whether option A can log in there); or leave it to criterion 14 and the first token-mode ECR.
  - **Blocks the build: no.** The design fails visibly with exit 7 in either case. A result of 0 would open a hub item for a token file.

### 13. Lead decisions (2026-11-10)

- L1: keep the catalog detector as warn-only.
- L2: the initial table is `claude-fable-5-2` 40, `claude-opus-5-5` 20, `claude-sonnet-5-5` 10. Haiku is left out, so if X is under 10 the result is "no model" rather than a small review voice.
- L3: a served model that differs from the requested one counts as responding and is flagged.
- L4: no tools (`--tools ""`).
- L5: an invalid row is left out and named, and `tests/thresholds.bats` refuses a bad table at the write boundary.
- Probe bound: later probes and tests stub `claude`. No real model call happens before criterion 14.
- L6: accept that the Claude voice's tokens are not in the work-item store; the voice prints a usage line instead.

### Change log

Round 1 design review (FAIL) to round 2:

- **B1 (child environment):**
  - Section 4.2 adds an allow-list started with `env -i`, names every cleared session, entrypoint, credential, billing and model variable, and adds a settings-file pre-check.
  - A no-model-call `claude auth status --json` check runs before the call, and an `apiKeySource` / `provider` check after it. Both lead to the new exit 7.
  - Failure rows 19 to 21. The AC 8 bats case records the env names and asserts that each denied name is absent.
- **B2 (catalog detector):**
  - Section 4.5 specifies the directory, the file checks (regular, not a symlink, owned by the user, at most 256 KiB, version and surface, epochs), the newest-`fetchedAt` rule with stale marking and a 7-day cut-off, the jq path, and the ID regex with count-not-echo.
  - New threshold `ecr-anthropic-unranked` with Haiku 5.5 and Fable 5.1 (section 5), so L2 does not warn every run.
  - Bats cases for row 9, for two files and for a stale file (section 8).
- **B3 (blocking questions):** O1 to O4 each say whether they block the build and what the build does if unanswered. O1's unit blocks; O2's "no price limit" removes X; criterion 14 waits on X (section 12).
- **N1 (hooks in the child):** section 4.3 states which hooks run ungated (`alfred-workitem` Stop and SessionEnd), why clearing the entrypoint avoids hub notices, and the SessionStart context. It chooses to accept the token-attribution gap, with a `usage:` line (L6).
- **N2 (agent file):** option B2 (`agents/ecr-voice.md` with a full-ID `model`) is added and dismissed under criterion 1 (section 2.1).
- **N3 (R2):** the R2 reason is restated: it needs the same per-ID table, and it misranks when a newer model is cheaper (section 2.3).
- **N4 (criterion 6 scope):** criterion 6 covers the table and X only, not the catalog (section 6).
- **N5 (bats for rows 2 and 7):** cases for row 2 (missing, symlink, empty, too large, exactly at the limit) and for row 7 with no valid row, exit 3 (section 8).
- **N6 (new-model chain):** section 9 writes out the chain (row, release, pin bump, canary, cold restart) and discusses the config-delivery path (`ALFRED_THRESHOLDS`).
- **N7 (served check):** the served line also prints `usage_models=`, and the skill says that `source=response` may only echo the request (section 4.4).
- **N8 (SKILL.md lines):** section 3 lists every `SKILL.md` line that changes, including 13, 31, 107 and 271.
- **N9 (exit codes and repeat call):** `--resolve` lists exit 2. Line 111's repeat-call sentence is limited to the gateway voices.
- **Also:**
  - Section 5's table now carries the decided L2 rows, and the expected results follow them.
  - Section 12's lead questions point to section 13. Section 13 is unchanged.
  - No model call was made in this round: the only new probes were `claude --version` and `claude auth status --json` under the allow-list, plus file reads.

Round 2 design review (FAIL on R2-B1) to round 3:

- **R2-B1 (token login):** section 4.2 now passes `CLAUDE_CODE_OAUTH_TOKEN` through when the caller has it, and describes both login modes from `start-helpers.sh` lines 93-180.
  - The mode follows from what the caller has: a token gives token mode; otherwise the full login must be `ok`, by the `_full_login_state` rule with a margin of the call time plus 60 s.
  - The pre-check accepts `authMethod` `oauth_token` in token mode (seen with a fake token, no model call) and `claude.ai` in full-login mode. The accepted `apiKeySource` is `none` in both modes; for token mode this is confirmed only by the first real call (criterion 14).
  - Whether Claude Code passes the token to Bash children: the scrub is off and other credentials pass, but it could not be checked here, because the lead runs with `env -u CLAUDE_CODE_OAUTH_TOKEN`. If it does not, the voice exits 7 visibly; the way out is a hub item for a token file. New lead question L7 is a name-only check on a token-mode lead.
  - Failure row 20b and a token-mode bats case next to the full-login case (AC 8).
- **N1 (AC 8 wording):** `env.names` holds only allow-listed names, and `ALFRED_ROLE` is present.
- **N2 (criterion 4):** "once per run" counts `-p` model calls, not `auth status`. Written as the lead's confirmed reading (AC 4).
- **N3 (auth status):** it runs with `timeout 20` and has its own failure row, 20a (timeout, non-zero exit, not JSON), with bats cases.
- **N4 (L6):** restated: the child's tokens most likely never reach the store (`OTEL_*` are not in Bash children, and telemetry variables are not passed). Added to the spend item in section 10. Section 13 gains the one allowed line, L6.
- **N5 (effort):** new threshold `ecr-anthropic-effort` (string, five levels, file value `high`), passed as `--effort`. `CLAUDE_CODE_EFFORT_LEVEL` is cleared, because it would override the flag, and a settings `env` entry for it gives a note. Failure row 20c.
- **N6 (settings path):** the settings path uses `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
- **N7 (exit precedence):** the full order is stated: 2, 3, 4, 7 (before the call); then 7, 5, 6, 1, 0 (after it). 7 wins over 5, 6 and 1.
- **N8 (catalog file choice):** the file checks run first on every match; more than 16 candidates gives "too many files" and nothing is read. The file is picked by the highest `fetchedAt`, not by name, and the newest file is never replaced by an older one when its shape is bad. New bats cases.
- **N9 (unranked overlap):** on an overlap the table wins; silenced IDs print once as `note: unranked by choice: <ids>`. New bats case.
- **N10 (docs):** the §11 items are closed from the Claude Code docs: the Agent tool takes only aliases, and the frontmatter `model` takes a full ID.
- **Also:**
  - Thresholds are now four (README, AC 11). AC 12 now applies to the passed token.
  - Override mode still reads the effort threshold and runs the login checks.
  - No model call in this round. Only name-only env checks, file reads, `claude auth status --json` (with the real login and with a fake token, `timeout 20`) and docs reads. No value was printed.

Round 3 design review (FAIL on R3-B1, accepted by the hub as a build condition) to round 4:

- **R3-B1 (secret in argv):** `env -i NAME=value` is gone from the design.
  - A `run_child` function (section 4.2) unsets every exported name outside the allow-list by looping over `compgen -e`, and also removes exported functions. It fails closed on a name it cannot clear, exports `ALFRED_ROLE=worker LANG=C.UTF-8`, and execs `timeout ... claude ...`.
  - It is used for both `auth status` and `-p`, and the same rule covers `HTTPS_PROXY` and the other proxy names.
  - Fixed in §4.2, §4.3 (the call block) and §11, where both `auth status` probes were re-run with the `run_child` pattern: `claude.ai` / `oauth_token`, both `firstParty`.
  - The round 1 change-log entry that mentions `env -i` is kept as history.
- **R3-B1 test:** new AC 8/12 bats case with stub `timeout` and `env` first on `PATH`. A fake token and a fake proxy password must be absent from every recorded argv line and output, present only as environment names, with no `env` call and exactly two `timeout` calls.
- **R3-B1 review:** the code-review plan in §8 makes R3-B1 an explicit adversarial lens: any secret in argv, an env prefix or `/proc` is CRITICAL.
- **Condition 1 (exit-7 text):** the exit-7 "no login for the voice" text (§4.2, failure row 20b) and the exit-7 row of the skill's exit table (§4.6) name the known causes and fixes: renew the full login; L7 and a hub item for a token file; the token-mode `apiKeySource` fix path.
- **Condition 2 (`apiKeySource` fix path):** §4.2 gives the fix path if token mode reports an `apiKeySource` other than `none`: a visible exit 7, record the value, check it is an OAuth source, then a one-literal patch with a bats case. A new always-printed `credential:` line lets criterion 14 and the first token-mode ECR record the value.
- **Condition 3 (effort):** the exit-6 rejection of an unsupported effort is marked not verified. Claude Code reports no effort field to check against, so the script prints the requested effort only.
- **Also:** section 13 is unchanged. No model call: the only commands were two `claude auth status --json` runs, one with a fake token, under `timeout 20`.
