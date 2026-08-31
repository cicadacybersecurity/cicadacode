---
name: openclaw-specialist
description: OpenClaw specialist layer for the OpenClaw self-hosted AI agent gateway. Use for any task involving OpenClaw — openclaw.json config, SKILL.md skills (authoring, precedence, gating, debugging), agents, model routing, channels, plugins, tools/permissions, sessions, Gateway service, openclaw CLI, diagnosing installations.
---

# OpenClaw Specialist

OpenClaw: self-hosted personal AI agent gateway. A long-running Gateway process connects messaging channels (WhatsApp, Telegram, Discord, …) to configured agents, each with its own workspace, model routing, tools, plugins, and skills.

General engineering competence (shell, git, Python/TS, Linux, LLM basics) is assumed — stay OpenClaw-specific. This file tells you where to look, not what you will find — inspect the live system; never trust memory.

## 1. Never invent OpenClaw facts

Config keys, CLI commands/flags, paths, env vars, tool names, plugin fields, SKILL.md frontmatter, and architecture change between versions. Treat anything not verified this session as unconfirmed, and verify it before relying on it.

Source hierarchy, strict order:
1. Installed OpenClaw: `openclaw --version`, `openclaw <cmd> --help`, `openclaw config schema`, package source (incl. repo `docs/`), live state (`openclaw status`, `openclaw skills list --verbose`).
2. Official docs `https://docs.openclaw.ai` (mirrors repo `docs/`).
3. The user's existing config, workspaces, skills, state on disk.
4. General knowledge — last resort, label unverified.

Label confidence: `[verified-install]` / `[verified-docs]` / `[inferred]` / `[uncertain]` (state what would verify it).

Docs vs. install conflict → stop, investigate (version drift, renamed or plugin-owned key), trust schema + source, report the discrepancy.

## 2. Orientation first (read-only)

Run only the steps the task and environment warrant — do not execute every orientation command blindly; a trivial change may need only steps 1–3. When a command's availability or syntax is uncertain, check `openclaw <cmd> --help` before running it.

1. `openclaw --version` — everything keys off this. `clawdbot`/`moltbot` binary = legacy install (§10).
2. `openclaw status --all [--json]` — active config path, gateway reachability, agents, channels, secrets diagnostics.
3. Config: default `~/.openclaw/openclaw.json`, or `OPENCLAW_CONFIG_PATH`. Read it fully before edits.
4. State: `OPENCLAW_STATE_DIR`, default `~/.openclaw/` — credentials, sessions, managed skills, logs.
5. Workspaces: `agents.defaults.workspace` + `agents.entries.<id>.workspace` (per-agent).
6. `openclaw gateway status`; `openclaw agents list` + `openclaw agents bindings`.
7. If diagnostic: skim `openclaw logs`.

`--profile <name>` / `OPENCLAW_GATEWAY_URL` change the target installation; if set, re-derive every path for that target. Editing the right file in the wrong install is the most common OpenClaw mistake.

## 3. Mental model

| Component | Role | Inspect |
|---|---|---|
| Gateway | Long-running WebSocket control plane; owns channels, sessions, runtime; service under launchd/systemd/schtasks | `openclaw gateway status`, `openclaw logs` |
| Agent | Persona + runtime: workspace, model, tools, skills | `agents.defaults` / `agents.entries.<id>`; `openclaw agents list` |
| Session | Conversation state per DM/group; sqlite per agent | `openclaw sessions`; `<state>/agents/<id>/agent/` |
| Channel | Messaging integration + access control | `channels.<name>`; `openclaw channels status --probe` |
| Tool | Agent capability (exec, browser, memory, plugin tools); policy-gated | `tools.*` schema |
| Skill | SKILL.md + support files; teaches tool use | §5 |
| Plugin | `openclaw.plugin.json` package: tools, skills, channels, provider slots | §6; `config schema` (plugin keys merged in) |
| Workspace | Per-agent dir: AGENTS.md / SOUL.md / MEMORY.md / TOOLS.md + `skills/` | read it directly |
| State dir | Config, credentials, sessions, managed skills, logs | `~/.openclaw` |

## 4. openclaw.json

Facts: JSON5 (comments/trailing commas — preserve them); all fields optional; root keys = infrastructure + cross-agent defaults, `agents.defaults` = agent-loop defaults, `agents.entries.<id>` = per-agent overrides; OpenClaw-owned writes are atomic and replace symlinks — use `OPENCLAW_CONFIG_PATH`, not symlinked configs.

Edit procedure:
1. Read the whole file; everything you do not touch must survive unchanged.
2. Schema truth for the exact path: gateway tool `config.schema.lookup`, or `openclaw config schema`.
3. Smallest possible diff. Never regenerate or reformat the file.
4. Back up: `cp openclaw.json openclaw.json.bak-<timestamp>`.
5. Validate: JSON5 parse + `openclaw doctor` or a gateway probe.
6. Apply: cached config needs `openclaw gateway restart`; skill-file changes apply next agent turn via the watcher (unless disabled). Verify which applies — do not assume.
7. Verify the effect: `status --all`, `channels status --probe`, or a controlled test message.

Secrets: never in prompts, logs, files, or chat. Use SecretRef (`secrets.providers`: env/file/exec) or `skills.entries.<name>.apiKey` / `.env` (host process, one agent turn, never the sandbox).

## 5. Skills

**Anatomy:** one dir per skill; `SKILL.md` (exact case) at root; support files referenced via `{baseDir}`. Body = YAML frontmatter + imperative markdown. The model sees only `name` + `description` until the skill is selected — keep the body lean, push bulk into support files.

**Frontmatter:** required `name`, `description`. Optional: `user-invocable` (default true → slash command), `disable-model-invocation` (slash / `$name` reference only), `command-dispatch: "tool"` + `command-tool` (slash bypasses model), `homepage`. Gating under `metadata.openclaw`: `requires.bins` (all on PATH), `requires.anyBins` (≥1), `requires.env`, `requires.config` (openclaw.json paths truthy), `primaryEnv`, `os`, `always` (bypasses bins/env/config, not `os`). Parsing: YAML first, single-line fallback; nested `metadata` flattened → JSON5. Legacy `metadata.clawdbot` honored when `metadata.openclaw` absent — always write `metadata.openclaw`.

**Precedence** (name collision → highest wins):
1. `<workspace>/skills`
2. `<workspace>/.agents/skills`
3. `~/.agents/skills` (default state dir only)
4. `<state-dir>/skills` (managed; target of `install --global`)
5. Bundled (+ Custodian library, custodian agent only)
6. `skills.load.extraDirs` + plugin skills

**Discovery:** any `SKILL.md` ≤6 levels under a root; grouping folders are organizational; skill name = frontmatter `name`, else dir name. Placement is a visibility choice: workspace = one agent; managed = all agents on that state dir; extraDirs = all agents on that config. Symlinked roots escaping the configured root are rejected unless `skills.load.allowSymlinkTargets`.

**Allowlists** (visibility ≠ location): `agents.defaults.skills` = baseline (omitted = unrestricted); `agents.entries.<id>.skills` replaces, never merges; `[]` = no skills. Applies to prompt building, slash discovery, sandbox sync, snapshots.

**Lifecycle:** `openclaw skills list --verbose [--agent <id>] [--eligible]` · `info <name>` · `check --agent <id>` (ground truth for what an agent actually sees) · `search` · `install @owner/slug | git:owner/repo[@ref] | ./path --as x` (`--global` → managed) · `update <slug> | --all` (ClawHub-tracked only; `--force` discards local edits) · `verify @owner/slug [--card]` · `workshop list/inspect/apply/reject` · remove via `clawhub uninstall @owner/slug` with the correct `--workdir`. Git/local installs expect `SKILL.md` at the source root; refresh them by reinstalling. `security.installPolicy` may gate installs — read its output, never force past it.

**Snapshots:** skills are snapshotted per session; file changes apply on the next agent turn via the watcher, else require a new session. `requires.*` changes do not refresh live snapshots. Filesystem ≠ what the agent sees — trust `check --agent`.

**Author/modify:**
1. `skills list --verbose --agent <id>` — inventory, collisions.
2. Pick the root by intended visibility; name must be free across all roots.
3. Read 1–2 ready skills in that root; match conventions.
4. Minimal frontmatter; gate only real dependencies. Third-party skills = untrusted code: read every file incl. scripts before enabling; `verify` ClawHub ones.
5. Validate: `skills info`, `check --agent`, a real turn or slash invocation. Respect snapshots before concluding "didn't load".

**Skill missing/not applying?** Exact `SKILL.md` casing, ≤6 levels under a configured root? Valid YAML with `name` + `description`? Shadowed by a same-named skill in a higher-precedence root (`list --verbose` shows the winner)? Gating failing (`list` marks `missing` with reasons; `requires.config` paths must be truthy in the *active* config)? Allowlisted out (`check --agent`)? `disable-model-invocation` set? Stale snapshot? Symlink rejection? Plugin disabled (plugin skills)? Node disconnected (node-hosted skills vanish on disconnect; restart the node after editing its files)?

## 6. Agents, models, tools, plugins

- Agents: `agents.defaults` + `agents.entries.<id>`; `openclaw agents list/add/set-identity`. Inbound routing: `openclaw agents bindings/bind/unbind`; multi-account channels key by agent id (`channels.discord.accounts.<id>`).
- Models: `model.primary: "provider/model"` + fallbacks + aliases, per-agent where the schema allows. `openclaw models list/status/set/set-image/aliases/fallbacks`. Provider auth via env, auth store, or SecretRef — never hardcode keys. `models status` = readiness.
- Tools: exposure gated by `tools.*` (+ per-agent overrides); sandbox/exec policy for shell-like tools. Inspect the schema node before editing; tighten, never widen by default.
- Plugins: manifest `openclaw.plugin.json`; register tools, skill dirs, channels, provider slots (e.g. `plugins.slots.memory`). Plugin-owned keys appear merged in `openclaw config schema` — that distinguishes core vs. plugin fields. Plugin skills merge at the lowest precedence tier; gate them via `requires.config` on the channel subtree (e.g. `channels.discord`), not on credential fields (creds may live under named accounts).
- Hooks/cron run unattended — read before modifying.

## 7. Channels, sessions

- Config: `channels.<name>` — `allowFrom`, group `requireMention`, `messages.groupChat.mentionPatterns`, multi-account setups.
- Diagnose: `channels status --probe`; `channels capabilities --channel <name> --target channel:<id>`; creds at `~/.openclaw/credentials/<channel>/<accountId>/` (check mtimes for staleness).
- Sessions: sqlite per agent under the state dir. `sessions cleanup` mutates state — confirm scope first. `openclaw agent` output carries `deliveryStatus` (sent/suppressed) — check it before blaming a channel.
- `/status` as a standalone chat command = liveness check without invoking the agent.

## 8. Gateway service

`openclaw gateway status|start|stop|restart|install|uninstall|run` (equivalent `daemon` subcommands); supervisor = launchd/systemd/schtasks, audited by `doctor`. Observability: `health --json`, `logs --follow` (filter e.g. `web-inbound`, `web-heartbeat`), `gateway diagnostics export`. Restart only when a cached config section changes — never "just in case"; capture state before restarting, a restart erases evidence.

## 9. Troubleshooting

Funnel: **symptom → component → state → logs → config → skill/plugin/source → root cause → targeted fix → validate.** One hypothesis, one change, re-test.

Symptom ≠ root cause: "silent on WhatsApp" can be creds, `allowFrom`, a missing binding, a down Gateway, provider auth, or a failing tool — eliminate by inspection, cheapest first. Capture `status --all --json`, `gateway status`, and recent logs before changing anything. `openclaw doctor` is the first-class diagnostic (config, supervisor, channels, memory provider, session sqlite) but `--fix` / `--yes` modify the system — read what it will change first. Never reinstall or reset as a first step.

| Symptom | Suspect first | First checks |
|---|---|---|
| Gateway unreachable | service, port, auth token | `gateway status`, service logs |
| Config rejected/ignored | JSON5 syntax, unknown/renamed/plugin-owned key | parse check, `config schema`, `doctor` |
| Skill missing | precedence, gating, allowlist, snapshot | §5 checklist |
| Skill misbehaves | instructions vs. tool contract | read SKILL.md + tool schema; test isolated |
| Wrong model / provider errors | model config, alias, fallback chain, auth | `models status`, config |
| Channel silent | creds, `allowFrom`, `requireMention`, binding | `channels status --probe`, creds mtimes, logs, `deliveryStatus` |
| Tool denied/failing | tools policy, sandbox, exec approvals | `tools.*` config, logs, `doctor` |
| Secrets unresolved | SecretRef source, env missing in service context | `status --all` secret diagnostics |
| Broke after upgrade | renamed keys, changed defaults, legacy names | changelog/docs diff, `doctor`, §10 |

## 10. Versions, legacy

Key all work to `openclaw --version`; never apply instructions written for another version. Pre-rename installs: `clawdbot`/`moltbot` binaries, `~/.clawdbot` state dir, `metadata.clawdbot` skill blocks (still honored as fallback). Docs-vs-install conflict → schema + source win; report the mismatch.

## 11. Safe modification protocol

Identify component + version → inspect current state → understand the exact section (schema/docs/source) → timestamped backup → minimal diff (preserve unrelated settings, comments, formatting) → validate (parse / schema / `skills check` / `doctor`) → apply (restart only what caches the change; respect snapshots) → verify externally → report.

Confirm with the user before: `gateway uninstall`, `sessions cleanup`, `skills update --force`, `doctor --fix`, credential deletion, `clawhub uninstall`, loosening `allowFrom`, rebinding production channels.

## 12. Never

Invent keys/commands/paths/fields · rewrite whole files when a small diff suffices · paste secrets anywhere · `doctor --fix` / reset / reinstall as a first resort · hand-edit sqlite or credential files when a CLI path exists · place skills in a random root · enable unread third-party skills · assume the CLI targets the local Gateway (profiles, `OPENCLAW_GATEWAY_URL`) · assume config edits apply live or skill edits need a restart — check · give generic Linux/Python/git tutoring.

## 13. Report

After work: **Changed** (exact paths, keys, commands) · **Verified** (checks + results, labeled `[verified-install]`/`[verified-docs]`) · **Open** (`[inferred]`/`[uncertain]` + how to confirm) · **Rollback** (backup locations).

## 14. Reference map (consult on demand)

`openclaw <cmd> --help` (flags) · `openclaw config schema` / `config.schema.lookup` (fields) · docs.openclaw.ai: `gateway/configuration` (+`-reference`, `-examples`), `tools/skills`, `tools/skills-config`, `tools/creating-skills`, `tools/plugin`, `cli` (+`cli/skills`, `cli/doctor`, `cli/gateway`, `cli/agent`, `cli/status`), `gateway/doctor`, `gateway/health`, `gateway/sandboxing`, `gateway/security`, `nodes` · repo `docs/` + source = final arbiter when docs and behavior disagree · workspace `AGENTS.md`/`SOUL.md`/`MEMORY.md`/`TOOLS.md` = that agent's local conventions.
