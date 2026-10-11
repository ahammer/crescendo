# Crescendo service

One Crescendo service runs several projects. Each project is a repository with its own
`WORKFLOW.md` (tracker, hooks, routing, autopilot, prompts), and every project shares the
service's worker slots, daily budget and Codex quota. Symphony's specification treats a
multi-project control plane as out of scope; this document describes Crescendo's.

Everything is configured in local files on the machine that runs the service. The dashboard and
the JSON API are read-only: nothing reachable over HTTP changes state.

## OpenAI Fast mode

The local operator MCP server runs with `crescendo mcp <crescendo.yml>` and exposes
`crescendo_priority_mode_get` and `crescendo_priority_mode_set`. The repository's
`.codex/config.toml` registers the installed CLI with the local service configuration.
The server uses newline-delimited JSON-RPC over stdio and never starts another orchestrator.

Set `{ "enabled": true }` to make Fast mode the service-wide default until disabled;
set `{ "enabled": false }` to restore standard speed. An optional `expires_at` uses an
ISO 8601 timestamp with a timezone. Without it the setting has no deadline. Changing the
default clears any previous deadline, and a deadline restores standard speed exactly when
reached for subsequent turns. Invalid changes leave the previous setting intact.

`paths.state/priority-mode.json` holds the atomic, persistent operator setting. Issues,
PR reviews, research and managed helpers use it when creating or resuming a native thread
and at every new turn. Codex receives `serviceTier: fast` when enabled and `default` when
disabled or expired; its acknowledged provider tier is normally `priority`. Single-workflow
runtimes retain their existing native defaults. Running turns finish with their existing tier;
they are not cancelled by a preference change. Workers identified by `CRESCENDO_WORK_ITEM`
can read the MCP status but cannot call its mutation tool. Model/effort routing, helper
isolation, scheduling, quota limits and admission remain independent.

The dashboard shows **Fast mode: On/Off**, with an optional deadline. Agent cards show **Fast**
when Codex reported that tier at thread startup. The read-only state API exposes `priority_mode`;
thread provenance retains the native acknowledgement. No HTTP mutation or dashboard toggle exists.
Unreadable or corrupt policies select standard speed and expose a policy error.

[Official OpenAI speed documentation](https://learn.chatgpt.com/docs/agent-configuration/speed#fast-mode)
lists supported Sol, Astra and Luna models. Included subscription allowance is consumed at 2.5x
the Standard rate, while purchased credits use 2x; these are not guaranteed speed multipliers.
Dashboard API-equivalent USD estimates continue to use configured model rates and do not measure
subscription debits or include a service-tier surcharge.

## Additional read-only capacity and quiet windows

Primary capacity remains `pool.slots`. Optional `helpers` adds a separate global pool (0–5,
default 0) of `gpt-6-luna` / `max` read-only leaf agents, with `timeout_ms` at most 900000.
Use `helper_start` for a bounded question, poll `helper_status` while doing independent work,
and cancel unused work with `helper_cancel`. Helpers consume account usage but no primary
slot or machine lease. Parent exit cancels them; capacity releases only after process exit.
Source reads are pinned to a Git commit and ignore replacement refs. Evidence is captured as
bounded text through no-follow traversal. Shell, editing, browser, apps, MCP and nested
agents are disabled, including capabilities forced by native model catalog metadata.
Inherited MCP servers are disabled before native startup using one nested `mcp_servers` map.
CLI map overrides are TOML inline tables; thread configuration carries the same nested JSON map.
Server names remain literal keys, preserving punctuation and existing transport definitions with
`enabled=false`. Invalid configuration fails closed without changing lead MCP configuration.
Catalogs are passed in sealed anonymous memory files; no mutable catalog path or per-run file accumulates.
Native approval and user-input requests are answered without contacting a human.

Optional `quiet_window` supports an owner-confirmed, same-day America/Vancouver window:

```yaml
pool: {slots: 3}
helpers: {slots: 5, model: gpt-6-luna, effort: max, timeout_ms: 900000}
quiet_window: {start: "03:00", end: "04:00", time_zone: America/Vancouver, drain_minutes: 60}
```

Only otherwise admitted `<prefix>:quiet` work reserves that window. Primary work and helpers
yield before it; a quiet run holds global exclusivity, and unfinished work yields at its end.
The native scheduling clock is cached per local day and follows installed timezone rules.
A missing/failed clock does not admit quiet work. Metalrain's lease independently verifies
the clock, complete service snapshot and sole owning run, and enforces the cutoff.

Autopilot task fields `exclusive: none|global` override project research exclusivity.
`skip_unchanged: true` performs a native preflight before workspace/model startup. It requires
fresh complete source/dependency/PR inputs, findings, policy and protected execution state.
Unknown inputs defer. Unchanged inputs advance a separate cursor, preserve completion/audit
coverage and force a recheck within 24 hours.

Prepared local issue workers can call `defer_quiet_acceptance` once per canonical logical attempt
when this configured window is unavailable. Commit preparation and evidence first, retain one draft
PR, and supply its URL, exact source commit, committed evidence paths, a durable reason and every
unmet acceptance gate. Failed p99/product gates remain failures. A successful request is persisted
before acknowledgment; update the workpad and end the turn without a blocked label. The worker
yields at the completed turn, freeing its slot for independent work without spending another attempt.

The same issue/attempt, final-attempt disposition, PR and evidence digests survive restart.
Normal tracker polling wakes the continuation only in the current configured quiet window, with
dependencies, quota/throttle, deployment drain and quiet exclusivity intact. A fresh resume prompt
revalidates the source/evidence identity and requires task/environment applicability checks;
changed, dirty or missing source/evidence is marked inapplicable. Acceptance remains incomplete
until the gates pass; final attempts still deliver reduced scope or retire under the existing rules.
Untracked nonignored files make source dirty; ignored generated artifacts remain usable.
Evidence must be committed regular files, not symlinks.
The read-only `deferred` state contains retained reason, source/evidence, PR and wake identities,
and `upcoming.waiting` displays the reason. Private-project details are redacted. This adds no local
configuration and does not change the existing quiet-label policy for whole runs.
Closed or no-longer-visible issues, failed logical attempts and retired deliveries clear their
saved continuation while retaining the canonical budget. Failed tracker reads preserve the record.
Removing the configured quiet window on restart ends an active, routable canonical delivery's deferral on
its next successful tracker observation through the existing failure policy. Autopilot counts that
original attempt once, then retries or retires its original owner at the configured limit. Missing
quiet acceptance and product failures remain unmet; removing the window cannot pass them.
A replacement project check-in also reclaims the stopped orchestrator's service slots and quiet
reservation before returning dispatch policy. A pending exit notification cannot leave quiet
admission held after the window; saved continuations retain their canonical identities and budgets.

The state API exposes `helpers`, `throttle.helpers`, `throttle.quiet_window`, `pacing`, and
`usage.planning` (retained skip, promotion and startup events). Managed helper tokens have
independent native run/thread attribution. `usage.external` keeps unverified reviewer/planner
CLI observations separate from native allocations and budget admission; actual account debits
remain unknown without native evidence. The soft pacing target is 90% of the observed reset
epoch, with a 10% allowance; it does not replace daily budget or low-quota guards.

For rollout, begin with two helpers for one day. Advance to five after normal traffic confirms
bounded output, source identity, cancellation, accounting and drain recovery. Compare 12–20
ordinary accepted deliveries by elapsed time, lease wait/held time, retries, valid acceptance,
managed helper cost and separately reported review/planning cost. Leave conclusions pending
until that cohort exists; do not run duplicate benchmarks to consume spare quota.

## Layout

```
~/.config/crescendo/
  crescendo.yml                        # the service: slots, throttle, pricing, defaults, projects
  projects/<id>/WORKFLOW.md            # one project (the same schema as a single-workflow run)
  projects/<id>/prompts/...            # prompt files referenced from that WORKFLOW.md
~/.local/state/crescendo/              # state (paths.state)
  projects/<id>/operations.dets        # each project's run, spend and activity history
  quota.term                           # the last Codex quota snapshot
  drain                                # manual or legacy admission hold
  deploy-drain.json                     # private managed owner/lifecycle transaction
  deploy-drain.lock                     # kernel lock retained by deploy and swap children
```

## First service

From `elixir/`, choose a configuration directory and a GitHub repository you can access. Replace
`your-org/your-repo` with its `owner/name`; the generated workflow uses that repository and its
default `main` branch (pass `--branch` to `project add` if yours differs).

```bash
CRESCENDO_DIR="${CRESCENDO_DIR:-$HOME/.config/crescendo}"
REPO=your-org/your-repo
mkdir -p "$CRESCENDO_DIR"
mise exec -- ./bin/crescendo project add "$CRESCENDO_DIR/crescendo.yml" demo "$REPO"
cat > "$CRESCENDO_DIR/crescendo.yml" <<'YAML'
server: {host: 127.0.0.1, port: 4280}
paths: {state: state}
pool: {slots: 1}
projects:
  demo: {weight: 1}
YAML
```

`project add` creates `projects/demo/WORKFLOW.md` and two prompt files, then prints the entry to
put under `projects:`. It does not create or update `crescendo.yml`; the `cat` command creates it.
The relative `state` path keeps state under `$CRESCENDO_DIR/state`. Change the loopback port if
4280 is already in use.

The generated GitHub workflow needs a `GITHUB_TOKEN` with permission to read and write issues,
pull requests and contents, and to merge. Authenticate `gh` on this host and ensure SSH can clone
the repository in the generated `after_create` hook. Create its required labels before launching:

```bash
gh auth status
export GITHUB_TOKEN="$(gh auth token)"
mise exec -- ./bin/crescendo labels sync "$CRESCENDO_DIR/crescendo.yml" demo
mise exec -- ./bin/crescendo "$CRESCENDO_DIR/crescendo.yml" --logs-root "$CRESCENDO_DIR/logs" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Start the service with the service file instead of a `WORKFLOW.md`. Project workflows and their
prompt files hot-reload as before. Adding, removing or reweighting a project, or changing the
service file, needs a service restart. A project whose workflow cannot load is reported on the
dashboard (its filter pill is marked) and the other projects still run.

Workspace hooks use each project's `hooks.timeout_ms`, independently of Codex inactivity.
The orchestrator tracks workspace preparation, Codex startup/execution, and `after_run` cleanup;
`codex.stall_timeout_ms` applies only during Codex startup/execution, with a fresh deadline after
preparation. Startup also retains `codex.read_timeout_ms`. Mandatory hook failures use startup admission retries;
cleanup failures are best effort. Slots remain occupied through cleanup and are released once
on worker exit or reconciliation. Workflow reloads preserve phases; runtime restarts cancel
workers together with their scheduler before redispatch.
Due retries and retries held for admission stay in weighted slot demand, while future backoff
does not reserve a slot. Retry timers refresh the slot policy before checking capacity.

Startup admission failures have their own budget, with or without autopilot. Workspace preparation,
mandatory `after_create`/`before_run` hooks, app-server session initialization and worker spawn
failures occur before model admission. They never advance `agent.max_attempts`, the logical item
attempt/effort ladder, research delivery attempts or the PR review cap, and never retire tracker
items or their dependencies. Zero tokens alone does not establish startup failure; once the
session is admitted, delivery and independent acceptance policies apply normally.

The first two failed starts retry after 10 and 20 seconds. After the third, the dashboard shows a
startup block and the scheduler permits one recovery probe every 30 minutes. Failed probes stay
blocked; successful admission clears startup accounting. Backoff and the capped failure count are
stored in `operations.dets` using wall-clock deadlines and survive restart. No worker slot or claim
is held during backoff. Fixing the environment allows recovery at the next probe; changing the
project's hooks, workspace, worker or Codex configuration permits an immediate controlled retry.
Keep the issue ready and preserve its dependency graph; no dashboard write endpoint is involved.
Configuration reloads and stale worker/run/timer identity checks prevent duplicate workers.

Existing workflows need no new settings. Startup admission uses this policy even when
`agent.max_attempts` is unset or `autopilot.max_item_attempts` is one. Mandatory hooks still abort
on failure; `after_run` remains best effort, with its separate hook deadline. Local hooks and SSH
transport subprocesses use Erlang port process groups so timeout/cancellation terminates their
children. Remote hooks require the standard GNU `timeout` utility (including `-k`) to enforce the
hook deadline on the worker; missing utilities fail visibly before model work.

History records `startup_failed`, `startup_retry` and `startup_blocked` separately from delivery
failures, with phase, hook, exit/timeout status, run/worker identity and bounded sanitized context.
Captured empty output is explicitly marked, without attributing a root cause. Timeout diagnostics
say when no output was captured. Private-project redaction also removes these diagnostics.

## Install and deploy

`ops/install.sh` installs the scripts to `~/.local/lib/crescendo/bin` and the systemd user units.
It never enables a unit or overwrites local configuration.

- `bin/start` runs the service from the release `CRESCENDO_RELEASE` (in `service.env`) points at.
  `CRESCENDO_LOCK` names a lock that anything else must not share; `CRESCENDO_CODEX_VERSION`
  optionally pins codex.
- `bin/crescendo` runs a command (below) with the deployed release, from any directory.
- `bin/deploy`, run by `crescendo-deploy.timer` every 10 minutes, deploys the newest `main`:
  1. Under the owner lock, it recovers any interrupted swap by restoring and health-checking the
     previous release before checking whether the target is already selected. It builds
     `releases/<sha>` and passes the full `make all` gate under the machine lease.
  2. It drains, so no new runs start and active issue workers yield after a successful native turn
     (it waits up to five minutes, then postpones). A postponement leaves at least thirty minutes
     for dispatch before another busy
     drain, even for a newer candidate. Each invocation selects the newest `main`, coalescing
     superseded candidates. A fully idle service bypasses the pause and deploys immediately;
     the running count is checked again after acquiring the hold. Unknown or partial snapshots
     keep the drain waiting; Governor-held slots also
     prevent an empty observed running list from ending the drain. Unknown held-slot counts
     keep the drain waiting too.
  3. It points `service.env` at the release and restarts the service.
  4. It waits for a complete, unfiltered state response with every project started, no project
     failure, every project snapshot `ok`, `tracker_ready: true` for every enabled project, and
     known Governor-held slot counts; otherwise it rolls back. The existing wait makes up to 24
     attempts, five seconds apart, with a ten-second HTTP timeout per attempt.

  A release that fails its gate or health check is not tried again. Each outcome is appended to
  `<state>/deploys.jsonl`, and the five newest releases are kept. `CRESCENDO_DRAIN_LIMIT_SECONDS`
  (default `300`) bounds each wait; `CRESCENDO_DISPATCH_PAUSE_SECONDS` (default `1800`) sets the
  minimum dispatch pause. Both must be positive. An explicit `CRESCENDO_DRAIN=0` retains the
  operator's immediate, interrupting deploy override; routine timer deployments never interrupt
  in-progress turns to meet the drain deadline. Long turns keep their existing execution deadlines,
  so a deployment is not guaranteed within one five-minute window. Existing manual drains are preserved.

  The journal is also the retry-policy state: `drain_started` includes a conservative retry deadline,
  and `drain_finished` records the result, actual start/end timestamps, elapsed hold seconds and
  observed idle seconds (zero running workers and zero Governor-held slots, including the swap).
  `drain_sample` records elapsed time, running/held slots, ready work, service capacity, quota pause
  and budget restriction every thirty seconds. Unknown snapshots record unknown running counts;
  they never count as idle. These observations measure deployment holds separately from quota,
  budget and no ready work; they do not claim that every unused slot could have dispatched eligible
  work. Idle durations are sampled estimates, not historical attribution. Cleanup releases only
  this invocation's pre-swap hold after postponement or cancellation, and a swapped hold only
  after deployment or rollback is healthy. An interrupted or unhealthy swap stays held for recovery.
  Gate failures occur before the hold. Dispatch resumes before release cleanup and script install.

Managed deploys use `<state>/deploy-drain.json` separately from the manual `<state>/drain` flag.
The transaction is atomically published before journal appends; the deploy and its swap children
retain an inherited kernel lock. No live owner expires from age. Governor admission checks acquire
that same lock to reconcile an abandoned pre-swap hold and record `drain_finished` with result
`abandoned`. New dispatch then resumes with worker slots, spend, workspaces and logical attempt
budgets intact. Failed lifecycle appends keep the hold until journalling can recover.

The swap phase is published before changing the release selection. A dead owner in that phase
reports `recovery_required`; admission stays held until the next deploy restores the saved previous
configuration, restarts and passes the existing health check. Cancellation during a swap follows
this recovery path. A failed restart, unhealthy rollback, missing backup or malformed ownership
state stays held. Recovery happens before the unchanged-target early exit. Manual on/off cannot
release managed state; legacy flags stay intentional-or-unknown and are never automatically removed.
Manual CLI transitions record credential-free lifecycle events through the same locked journal
appender, preserving events after a truncated record. The CLI reports lifecycle append errors.

`throttle.drain_owner` and admission history distinguish `managed`, `manual`, `legacy_unknown` and
`quiet` holds. Managed evidence includes phase, start time, commit and owner status (`live`,
`abandoned`, `recovery_required`, `unknown`); quiet phases are `preparing` and `finishing`. Private
owner tokens, commands and host paths are excluded. Dashboard/API reads only observe; normal
Governor admission checks perform reconciliation. Historical unknown holds are not backfilled.
The October 9–10 retained samples and fully finished managed journal operations cannot determine
whether that cycle's long hold was manual, quiet or an unjournalled abandoned deployment.

The service's read-only state API and dashboard mark each project's snapshot as `ok`, `timeout`,
`unavailable`, or `not_selected` (outside the filter). Unknown running/ready counts are `null`.
The selected aggregate reports `snapshot_status: complete|partial` and `snapshot_errors` with
project/status pairs. Partial reads preserve observed work and private-project redaction, but
aggregate `counts` are `null`, health warns and the dashboard shows unknown counts. Governor-held
service slots can still be shown; they do not imply a queue count. A successful read clears the
warning. `ops/bin/deploy-state.py` validates deployment observations independently of the deploy
script. Its validation modes read JSON from stdin; its drain mode reads the state API and owns
only managed ownership state and the journal. The deployed Elixir release embeds the same Python
policy from `ops/bin/deploy-state.py`; managed observations and manual lifecycle journalling require
`python3` and kernel `flock` support.
The policy never restarts the service.

`projects[].tracker_ready` comes from each Orchestrator's in-memory successful active-issue poll
observation and latest poll/configuration error. It starts false in each process generation,
including restarts that restore persisted PR inventory, becomes true after a successful poll,
and becomes false on poll failure until recovery. Unavailable or unselected snapshots report
`null`. A responsive process, fresh sibling, empty queue or PR inventory cannot establish this
readiness. Idle and quiet-held projects remain healthy after polling. This health requirement
does not change drain slot/helper accounting or expose tracker errors, credentials or local paths.

The current service admission holds appear in `throttle.draining` and
`throttle.research_hold` (`null` or `{project, phase}`). A global research request waiting for
idle reports `phase: reserved`; running global research reports `phase: running`. Reservations
disappear at expiry, and project/none exclusivity does not create a global hold. The dashboard's
Dispatch health detail explains these holds, including in project filters and partial snapshots.
Only the already-public project ID is exposed, with no private work or task details. Admission
policy stays unchanged; intentional holds are informational, and unknown counts remain unknown.
`draining` covers a present dispatch drain flag, quiet preparation, or a quiet run finishing
outside its active window. `throttle.drain_reason` reports `managed deployment drain is present`,
`interrupted deployment swap awaits verified rollback`, `dispatch drain flag is present`,
`preparing for quiet acceptance`, or `waiting for a quiet acceptance run to finish`; otherwise
it is `null`. A flag takes precedence over quiet holds. Manual flags have the same effect;
the message does not establish that a deployment is running. Each policy/snapshot captures the
quiet phase once for both the reason and returned phase, including at window boundaries.
Owner tokens, flag contents and paths stay private. Missing/legacy reasons remain unknown.
These read-only current signals
do not establish hold ownership, intended duration or the cause of historical unused capacity.

## Commands

These change local files, or a project's own repository through your `gh` login, never the
running service:

```bash
crescendo project add ~/.config/crescendo/crescendo.yml nubu3d ahammer/Nubu3D [--branch main] [--prefix crescendo] [--tools node@22,rust@1.82]
crescendo labels sync ~/.config/crescendo/crescendo.yml [nubu3d]
crescendo labels migrate ~/.config/crescendo/crescendo.yml metalrain --from symphony
crescendo drain on|off ~/.config/crescendo/crescendo.yml
crescendo autopilot check .crescendo/autopilot [--workflow ~/.config/crescendo/projects/<id>/WORKFLOW.md]
```

- `project add` writes `projects/<id>/` (a `WORKFLOW.md`, a pull request review prompt and a research
  prompt) from the built-in templates. It never overwrites, and it prints the line to add under
  `projects:`. `--prefix` follows the workflow's `labels.prefix` rules: it is trimmed and lowercased,
  then must contain only lowercase letters, digits or dashes. `--tools` puts mise tools in front of
  Codex, so the agent and everything it runs have them.
- `labels sync` creates every label a project's workflow uses that its repository lacks: ready,
  hold, in-review, blocked, one per research channel, sizes and model routes. It exits with an error
  if a requested project is unknown or GitHub cannot list or create the labels.
- `labels migrate` moves every open issue and pull request from each `<old>:` label to its twin under
  the project's `labels.prefix` (run `labels sync` first). Old labels stay for history. Runs get
  the prefix as `CRESCENDO_LABEL_PREFIX`, so repository tooling can follow the switch. It exits with
  an error if GitHub cannot list items or add/remove a label.
- `drain on` stops new runs; active issue workers yield at successful completed-turn boundaries.
  `drain off` removes only the manual/legacy flag; managed and quiet holds remain independent.
- `autopilot check` validates a repository's `.crescendo/autopilot/` folder: task front matter,
  schedules, deliveries and prompt templates. It prints one line per task. With `--workflow` it
  loads the folder exactly as the service would load it for that project, including task efforts
  against its ladder. Agents and the pull request reviewer run it on changes to the folder.

## `crescendo.yml`

```yaml
server: {host: 0.0.0.0, port: 4280}
paths: {state: ~/.local/state/crescendo}
pool: {slots: 3}
throttle:
  daily_budget_usd: 200
  backoff:
    - {window: weekly, remaining_below_percent: 3, pause: true}
pricing: {as_of: "2026-10-01", models: {gpt-6.1-sol: {input: 1.0, cached_input: 0.1, output: 5.0}}}
defaults:
  codex:
    routing: {...}          # anything a project's front matter may hold
projects:
  metalrain: {weight: 1, research_exclusive: global}
  nubu3d: {workflow: projects/nubu3d/WORKFLOW.md, cap: 1}
  shimmer: {enabled: false}
```

- `server` binds the dashboard and the state API for the whole service. A project's own `server`
  setting is ignored.
- `pool.slots` is the number of agent runs the whole service runs at once. A project's own
  `agent.max_concurrent_agents` still limits that project.
- `throttle` and `pricing` are service-wide (see [Throttling](#throttling)). A project's own
  `throttle` is ignored; its `pricing` is replaced by the service's.
- `defaults` is merged under every project's front matter: nested maps merge key by key and the
  project's own values win, so shared routing or agent limits live once.
- `projects` maps an id (lowercase letters, digits and dashes) to:
  - `workflow`: path to its `WORKFLOW.md`; default `projects/<id>/WORKFLOW.md` next to this file.
  - `weight` (default 1): its share of contested slots.
  - `cap`: the most slots it may hold at once.
  - `research_exclusive`: `none`, `project` (default) or `global` (see below).
  - `enabled` (default true).
  - `redact` (default false): keep a private repository's work off the public dashboard and API.
    Its items show only identifiers, links, kind, state, model, attempts, tokens and cost; titles,
    descriptions, messages, transcripts, plans, files, images, branches, errors and run ids are
    dropped.

Relative paths resolve against the service file's directory.

## Sharing slots

A Governor owns everything projects share. Orchestrators check in every poll, reporting their spend
today and how many runs they could start, and they get back the dispatch policy. They acquire a
slot right before a run starts and release it when the run ends. The Governor monitors each
orchestrator and frees the slots of one that stops.

- **Weights.** While several projects have work waiting, the next free slot goes to the project with
  the lowest *pass*. Each grant advances a project's pass by `1 / weight`, so over time grants
  follow the weights. A project returning from idle rejoins at the active projects' pass rather than
  spending credit it banked while idle. When a slot is kept for a project, that project is told to
  poll immediately.
- **Caps** limit a project on top of the shared slots.
- **Research exclusivity.**
  - `none`: research is an ordinary run.
  - `project`: research runs when its project is idle, and nothing else in that project starts
    until it finishes.
  - `global`: research needs the whole service idle and holds every slot while it runs. A global
    research request that finds other runs in flight reserves the service, so nothing new starts
    elsewhere until the research gets its turn. A reservation that is not renewed within 90 seconds
    lapses.
- **Drain.** While `<state>/drain` exists, nothing new starts. Service issue workers consult the
  Governor after successful native turn completion and checkpoint persistence, yielding before
  another turn. Normal cleanup runs and the orchestrator releases the slot once. The distinct
  `deployment_drain` interruption reason preserves source/workpad, logical attempt and retry count,
  including zero; it records no failed attempt, retirement or accepted delivery. Ordinary weighted scheduling
  resumes the issue after the hold ends, without requiring native thread reuse. Failed turns and checkpoint failures
  keep normal retry semantics. Standalone workflows, reload, stale-run updates, reconciliation and
  shutdown keep their existing behavior. Deploys use this hold; long in-progress turns and unknown
  observations continue waiting under the existing deadlines.

Waiting for a slot, the throttle or a backed-off route is never a failed attempt: a held retry keeps
its attempt number and checks again every 30 seconds.

## Throttling

- **Budget.** `throttle.daily_budget_usd` enforces estimated spend per UTC day across all projects.
  Over it, only `over_budget_allow` classes start. The default is `[pull_request, final_attempt,
  continuation]`; the other classes are `issue` and `research`. Open work keeps closing while
  nothing new begins.
- **Quota back-off.** Each `backoff` rule watches one Codex quota window (`weekly`, `daily`, `5h`,
  ...).
  - `avoid` swaps the listed models for the strongest allowed ladder step, never below the item's own
    or the default start. If no step is allowed, the run waits.
  - `pause: true` holds every new run until the window resets.

  Quota older than `quota_stale_ms` (default two hours), or never seen, counts as unknown. With
  `on_unknown_quota: restrict` (the default), unknown quota still avoids models but never pauses.
- **Pricing.** `pricing.models` overrides or adds model prices in USD per million tokens (`input`,
  `cached_input`, `output`). Unlisted models keep the built-in prices.

## Labels

`labels.prefix` in a project's `WORKFLOW.md` (default `symphony`) names the labels Crescendo reads
or applies itself, unless they are set explicitly:

- `<prefix>:model:*` and `<prefix>:size:*` routing labels;
- `<prefix>:blocked`;
- the `<prefix>:research` and `<prefix>:channel:<name>` labels on research runs.

Tracker `required_labels` and `excluded_labels` (for example `<prefix>:ready` and `<prefix>:hold`)
stay explicit.

## Research channels

When GitHub delivery attempts are exhausted, retirement closes the issue as not planned and
closes its owned drafts. Ownership requires a body line starting with `Closes #N`, `Fixes #N`,
`Resolves #N` (including singular/past forms), `Symphony issue: #N` or `Crescendo issue: #N`,
or an `issue-N` branch segment with an optional hyphenated suffix. The number must match exactly;
mentioning a prerequisite or baseline failure does not make a draft belong to that issue.
Non-draft PRs remain available for independent review.

A channel under `autopilot.channels` is its focus text, or an object:

```yaml
channels:
  qa:
    focus: "User-visible defects found by exercising the app on Linux desktop."
    prompt: prompts/research/qa.md     # this channel's own prompt (else prompts.research)
    min_issues: 2
    max_issues: 4
    route: {model: gpt-6.1-sol, effort: xhigh}
    every: 1d          # schedule: 30m, 6h, 1d, 2w (default research_cooldown_ms)
    at: "06:00"        # optional UTC calendar anchor (interval rounds up to days)
    when: idle         # idle: only when nothing else runs or waits; anytime: whenever a slot is free
```

Each channel (task) runs on its own schedule; the most overdue due task goes first. Without `at`,
`every` is measured from completion. With `at`, the first run is due at the latest UTC anchor at
or before now. After completion, the next due time is the latest anchor at or before the finish
plus `every` rounded up to whole UTC calendar days, with a minimum of one day. A daily 06:00 task
finishing October 1 at 19:12 stays due October 2 at 06:00. Finishing before 06:00 leaves that day's
06:00 due; finishing exactly at 06:00 leaves tomorrow due. Sub-day intervals with `at` run once
daily; `36h` rounds up to two days. Delays do not replay a backlog of missed occurrences.

A running task cannot dispatch again. Tasks requiring at least one PR also wait while an open PR
(including a draft) has their `<prefix>:channel:<name>` label, until it closes or merges. The hold
also applies to retries and does not mark the task completed or consume an attempt.

After a run, Crescendo counts the issues and pull requests it opened with their channel label.
A run that falls short of its minimums, or fails, is retried 30 minutes later behind other work.
The last allowed attempt (`max_item_attempts`) ends the task until it is next due, so nothing is
parked. The timeline shows each outcome as "delivered" or "fell short".

## Per-repo autopilot (`.crescendo/autopilot/`)

A repository can carry its own autopilot, which travels with its code:

```
.crescendo/autopilot/
  autopilot.yml      # optional: defaults: {every, when, effort}; guidelines: guidelines.md
  guidelines.md      # maintenance guidelines appended to EVERY agent prompt for this repo
  tasks/<name>.md    # one task: YAML front matter + its seed prompt
```

```markdown
---
focus: User-facing docs that are accurate, clear and sell the project
every: 1d
when: idle
effort: max                       # a rung of the project's local ladder; the model stays local
delivers:
  issues: {min: 0, max: 2}
  pull_requests: {min: 0, max: 3, paths: ["README.md", "docs/**"]}
expectations:
  - Run the documented quick start from a clean clone
---
You are the marketing lead for {{ issue.title }} ...
```

- **Mirroring:** the service reads the folder from the repository's default branch every five
  minutes (conditional requests, so an unchanged folder is free). It mirrors the folder into
  `<state>/projects/<id>/repo-autopilot/` and reloads the project when anything changes. The
  folder is read the same way as `WORKFLOW.md` prompt files.
- **Precedence:** when the folder has tasks, they **replace** the project's local
  `autopilot.channels`. Local config keeps what the service owns: the model and effort ladder,
  routes, budget, trust, tracker and `enabled`. Set `autopilot.repo_tasks: false` to ignore the
  folder, or `autopilot.disabled_tasks: [name]` to skip single tasks. Repositories without the
  folder keep their local channels.
- **Prompts:** the task body is the prompt, with the same variables as research prompts. Crescendo
  appends:
  - a `## Deliverables` section (counts, label, allowed pull request paths, expectations);
  - `## Repository guidelines` from `guidelines.md`, which reaches issue, review and task prompts
    alike.

  A pull request carrying a task's label is reviewed against that task's `paths`; the reviewer
  closes it as out of scope if it touches anything else.
- **Invalid folder:** an invalid folder keeps the last good configuration, and the error is logged.
  The dashboard's Autopilot card marks each project's tasks as `repo` or `local`, and flags a
  failed repository read.
- **Who can change it:** agents may change the folder through normal reviewed pull requests. The
  reviewer runs `crescendo autopilot check` on them.

### Marketing dept

Projects written by `project add` get a `marketing` channel with its own prompt
(`prompts/marketing.md`) and `min_issues: 0`. Instead of filing issues it reviews the user-facing
documentation (README, guides, examples, descriptions) against the current code, and opens
documentation-only pull requests that make it clearer, current and more persuasive. The reviewer
autopilot merges or closes them like any other pull request. "Nothing to change" is a valid outcome.

## What runs see

Every agent command and workspace hook of a run gets these variables:

| Variable | Meaning |
| --- | --- |
| `CRESCENDO_PROJECT` | The project id (unset for a single workflow). |
| `CRESCENDO_WORK_ITEM` | The qualified work item, e.g. `metalrain/GH-12`. |
| `CRESCENDO_STATE_URL` | The service's read-only state API. |
| `CRESCENDO_HOOK` | The hook being run (hooks only). |
| `SYMPHONY_WORK_ITEM` | The bare work item (`GH-12`). |
| `SYMPHONY_SELECTED_MODEL_LABEL` | The selected route label. |
| `SYMPHONY_STATE_URL` | Same as `CRESCENDO_STATE_URL`. |

The `SYMPHONY_*` names are kept for tools that predate the service.

## Dashboard and API

Polling and tracker health require successful tracker observations from every selected project.
Both checks warn before a first observation or when any selected project's data is older than
five of its own configured poll intervals; tracker errors make both checks critical.
A poll in progress does not hide stale data.
The combined tracker timestamp stays `null` if any selected project has no observation or its
snapshot is unavailable, otherwise it uses the oldest one. Fresh successful reads clear the
warnings. These are read-only signals; they do not restart projects or dispatch work.

Crescendo's state responses include service-wide `service: {revision, commit_url}` metadata,
including project-filtered, full-history and snapshot-error responses. `revision` is the full
40-character source commit and `commit_url` links to that commit in `ahammer/crescendo`.
The dashboard shows its short revision link, or "Revision unknown"; both metadata fields are
`null` when identity is unknown.

Source deployments archive the pinned commit into `releases/<sha>/source/elixir` and write an
empty `.built` marker after passing the gate. At startup one owner validates the compiled source
path and this marker, then retains only public commit metadata for the process lifetime.
Later main merges, environment values and workspace HEAD cannot change it. Missing, malformed
or unreadable build identities, development checkouts and Burrito packages report unknown;
release directories, host paths and environment values are never exposed by this metadata.
This adds no configuration, control or write endpoint.

- `/` shows every project; `/?project=<id>` filters to one.
- `/agents/<project>/<id>` is an agent's inspector. It omits the project's configured `labels.prefix`
  and every `<prefix>:` label before showing up to eight work labels. Single-workflow inspectors use
  that workflow's prefix (default `symphony`); an open inspector keeps its last resolved prefix if
  configuration becomes unavailable.
- `GET /api/v1/state[?project=<id>]` is the merged state, with every item tagged by `project`.
- Add `history=full` for retrospectives: `usage.activity` includes up to 2,000 retained events
  per selected project and `usage.samples` includes the retained 48 hours of five-minute samples.
  The default API and dashboard show the newest 100 events and 12 hours of samples. Project
  filtering, private-project redaction and partial-snapshot reporting apply to both views.
  Check the oldest timestamps before claiming a complete cycle; event eviction can shorten it.
  Daily totals and 14-day task averages keep their existing windows.
- `GET /api/v1/<project>/<id>` is one work item.

There are no write routes.

Five-minute capacity samples retain an `admission` observation from the Governor: `source: governor`,
`scope: service`, ISO8601 `observed_at`, shared `slots`, Governor-held `busy` slots, `draining`, `drain_reason`, and
`research_hold` (public project ID and `reserved`/`running` phase, or null). Project-only and
non-exclusive research are not global holds. Missing Governors and legacy samples have null
admission evidence; nothing is backfilled or inferred from worker counts. Legacy reasons stay unknown.

Service `usage.samples` carries one whole latest admission observation per bucket, with `observed_by`
identifying its recording project. Shared slots never sum across projects. `project_samples` retains
each selected project's independent counts, observation time and admission evidence. Aggregate counts
have `counts_scope: selected_projects`; `sample_status: partial` makes aggregate numeric counts null
when a selected project has no sample or its snapshot failed; sparklines omit these partial buckets.
Filtering never implies service-wide worker occupancy. Bucket `at` is not an observation time:
compare timestamps before attribution;
counts and holds from different polls are not one simultaneous fact. Holds show observed state, not
exact lost execution time or the cause of an older interval.

These fields use the existing latest-poll-per-bucket storage and retention: 48 hours in durable
Operations DETS, 12 hours in the default projection, and 48 hours with `history=full`. Restart retains
observations but never reconstructs older holds. Only capacity, public project IDs and phases are
published; task details and paths are excluded. Dashboard/API remain read-only; admission policy,
dispatch, fairness, weights, budgets and local configuration are unchanged.

Non-object Codex diagnostics remain in the worker's last-message summary. They do not stop the
project or free its workers: model/turn bookkeeping and optional notification capture validate
object envelopes and fields, then continue processing later valid notifications.


## Durable outcome facts

The existing Operations DETS ledger separates three observations:

- Run endings (`completed`, `failed`, `stopped`, `interrupted`) measure worker transport/turn
  completion, with wall time and recorded API-equivalent cost. A completed turn is not acceptance;
  stopping an accepted worker during reconciliation is not failure. Duplicate endings preserve the
  first ending and its time/cost.
- `attempt_failed` (or `blocked` without autopilot) measures a blocked item attempt, independently
  of its run ending. New facts retain the work item, item-attempt number and last recorded run ID.
  The durable item/attempt/run key prevents duplicate counting while distinguishing new attempts
  after a closed PR reopens and its retry budget resets. Issue budgets persist across closure.
- `item_disposition` records scoped acceptance or retirement. `merged` accepts the observed PR's
  scope; it does not claim full product acceptance. For deliveries without a PR, a closed issue
  carrying `<prefix>:delivery:verified-existing` accepts verified existing work; a closed issue with
  `<prefix>:delivery:split` accepts its documented delivered scope, leaving follow-ups outstanding.
  Here `<prefix>` is `labels.prefix`. Apply the label only after validation, and document evidence
  and unmet criteria in the workpad. Use these issue markers for deliveries without a merged PR,
  so the same delivered scope is not counted once as a PR and again as an issue.
  `not_planned` or successful autopilot retirement records `retirement`, never accepted delivery.
  Ordinary issue closure records `unknown` acceptance. Repeated reconciliation is idempotent:
  each item contributes at most one accepted delivery.

PR close/open events remain transitions: `pr_closed` followed by `pr_reopened` may later become
`pr_merged`. Close transitions are not abandoned deliveries. The dashboard labels completed turns,
blocked item attempts, scoped deliveries, retirements and unknown acceptance separately. The daily
series adds `stopped`, `blocked_attempts`, `accepted_deliveries`, `retirements` and
`unknown_dispositions`; existing run and PR-transition fields retain their meanings.

Counts use the retained 2,000-event history within the 14-day UTC series, not lifetime totals.
Idempotency keys and last recorded item/run correlations survive event eviction and restart.
Historical events without run IDs expose `attribution: unknown`; they are not retroactively joined
by timestamps or converted from normal completion/closure into acceptance. Historical blocked
attempts count as observed; their missing run/attempt identity cannot be reconstructed. Historical
merge transitions remain merge observations, without backfilled acceptance facts. Nested planner
and independent reviewer usage is not fully included in the recorded cost estimates.

### Bounded Codex notification transport

Codex stdio input uses a 16 MiB frame assembly ceiling and a separate 4 MiB RPC/control
payload ceiling. Partial turn-frame assembly has an absolute `codex.read_timeout_ms` deadline
from its first fragment, while complete stream updates retain the configured silence timeout.
Ordinary notifications drain during RPC waits; tool/approval requests use their
normal handlers, and terminal/input events and startup cumulative usage remain in the bounded
control queue (4 MiB / 1,024 entries). Codex 0.160.0 generated schema excerpts are checked in under
`elixir/test/fixtures/codex-0.160.0-output-schema.json`. Diagnostic copies of supported text deltas,
agent message text, command `aggregatedOutput`, notification command text (including
`commandActions` copies), file-change diffs and turn-level aggregated diffs retain at most 16 KiB
per field with an explicit truncation marker; raw diagnostic copies are also bounded. Only passive
notification copies are shortened: executable tool/approval requests retain their original commands
and arguments. RPC results, usage, model reroutes, item identity/status and terminal status are never
truncated. Existing dashboard transcript entry/output limits still apply.

A frame over 16 MiB, a response or irreducible control payload over 4 MiB, or saturation of the
control queue fails closed. Overflow diagnostics record the guard, observed bytes/count, phase,
request identity/method, thread/turn identity and work item without payload contents. After overflow,
the stream is unusable: account-usage RPC is skipped and the process group is closed during normal
worker cleanup. Admitted transport overflow records an infrastructure interruption and retries
after 30 seconds without advancing the implementation attempt; startup overflow retains startup
admission recovery. Research interruptions use the durable channel schedule and preserve the
channel's attempt count, rather than looking up synthetic IDs in the tracker. Optional native
context and checkpoint reads propagate transport overflow; a failed transport rejects all later
requests, including continuation turns. Native servers must split larger output into bounded delta
frames; this client does not stream arbitrary JSON strings or accept unbounded controls. Output-only
fields beyond the verified schema remain subject to the control payload ceiling. No billable model run is needed to
verify this transport behavior.

## Terminal thread usage reconciliation

Operations owns cumulative accounting after a worker completes, fails, is interrupted or is
force-stopped. Credential-free run attribution retains the scoped thread, item, model, price
rates and UTC allocation date in the existing 90-day run history. A late supported usage event
updates the original run's watermark and derived run/item/model/date/service estimates exactly
once. It cannot change worker actions, transcripts, routes, rate-limit controls, claims, retries,
issue disposition, governor slots or grant checkpoint eligibility. A thread subsequently resumed by
another run rejects observations attributed to its former owner.

`usage.accounting` reports `terminal_observed` and `incomplete` run counts over retained run
history; `usage.activity` carries each run's current `accounting_status`, `cache_write_status`
and corrected estimate. Terminal observation means a supported cumulative input/output snapshot
and a matching terminal turn were observed, including failed/interrupted turns. It does not
promise provider billing completeness. Starting another turn makes terminal accounting
incomplete until that turn's usage and terminal event are observed. Missing cache-write fields
remain `unknown`; cached input and reasoning output remain subsets, never additional tokens.
Observed turn usage evidence stays in bounded run history, so an older notification cannot erase
it when cumulative usage precedes the turn-start response.

The pinned Codex 0.160.0 generated schema exposes `thread/tokenUsage/updated.tokenUsage.total`.
`last` is not cumulative, `turn/completed` contains terminal status but no usage snapshot, and
`ThreadReadResponse.thread` has no token-usage field. Graceful teardown already reads the supported
native account estimate with a one-second timeout and flushes queued notifications; these
notifications now reach retained accounting even after worker removal. Force-killing a worker,
protocol failure or an absent provider event can leave accounting incomplete. No turn is launched
for telemetry, and no token-usage read RPC or Responses parameter is inferred from `thread/read`.

Reconciliation is bounded: during the retained 90-day window, replay only supported cumulative
notifications with verified original run/thread identity through Operations.reconcile_usage/5.
The orchestrator's late-message path uses this same function. Offline investigations must use
copied immutable native-event/ledger snapshots, validate identity and schema, and replay into a
scratch ledger; do not edit the live operational ledger. Beyond retention or without a supported
final observation, retain unknown coverage rather than inventing totals. Attribution expires
with existing run-history pruning; cumulative aggregate records remain available.

`test/fixtures/terminal-usage-gap.json` is a synthetic sanitized reproduction of the reported
512,557 input / 1,927 output aggregate gap, not recovered operational data. Deterministic tests
cover usage on either side of worker removal/terminal events, failure/interruption, duplicates,
stale events, compaction estimates, restart, redispatch, resumed-thread fencing and retention.
Separately launched helper/reviewer threads remain unobserved (`helper_usage_coverage: unknown`);
recorded parent-thread estimates must not be described as complete whole-project cost.


## Retained issue delivery evidence

Issue delivery associations are retained in the existing Operations lineage and exposed read-only
as `usage.delivery_metrics.issue_associations` (with project tags in service snapshots). The GitHub
inventory task follows prospectively tracked issue workers throughout retained run history, even
after completion, reconciliation or restart. Each inventory refresh rotates through at most ten
retained issue scopes, so delivery reconciliation cannot sweep every historical scope each minute.
It reads paginated issue cross-reference timelines
and PR observations. Ownership requires an explicit closing directive or an exact standalone
`Symphony issue: #<number>` line, a same-repository worker branch (`crescendo/<number>-...`,
`symphony/<number>-...` or optionally namespaced `issue-<number>` with an optional suffix) and PR creation
during a unique retained worker attempt. Titles and incidental references provide no ownership proof.
The original source/run association stays fixed across later review, merge, reopen and redispatch.
Canonical handoffs and split scope are captured at worker dispatch and terminal reconciliation.
Scope observed while a worker was active survives tracker edits before the first delivery
observation, including removal of the handoff record or split label.
Malformed handoff evidence retained from closure keeps acceptance unknown after marker removal.

The projection retains tracker observations, source and merge SHAs, evidence sources and timestamps,
attempts and canonical handoff ownership. Duplicate observations are idempotent; older tracker or
source timestamps cannot replace newer evidence. Completion with an owned merged source is
`repository_reported_completion`; proven split/handoff scope is `accepted_reduced_scope`, never
completion of the broader canonical outcome. Not-planned closure is `retirement`; closure without
proof is `unknown_acceptance`. Reopen is `open` and preserves earlier observations and sources.
These are repository-reported associations, not independently verified acceptance. Missing proof
and helper usage remain explicit. Verified delivery count, cost and latency stay null, and unknown
historical runs are not backfilled into accepted deliveries. Associations expire with the retained 90-day worker history; private-project associations are
removed from the public projection. No public mutation control or local configuration change is
introduced.

Canonical report-only `--verify-existing` delivery uses `repository_reported_verification`
with `delivery_kind: report_only` and separate `report_verifications`; it never invents a PR source.
The GitHub observer requires a completed closure with a matching final authenticated lifecycle event
and one unique exact-source canonical reference. It reads bounded regular files beneath the existing
private `METALRAIN_SYMPHONY_EVIDENCE_ROOT`: closure intent, input, acceptance, approved review,
clean source, adjudicated failures, unchanged review-input digest, hosted checks and reviewer identity.
Issue/repository identity, captured scope, source SHAs and reviewer work item must agree with the
observed issue. Hosted commit status and check-run SHAs must match the reviewed source. All failure
adjudication and unchanged-input checks remain required. Symlinked paths are rejected; ordinary
receipts are limited to 128 KiB and the committed reviewer log to 16 MiB. Raw receipts, paths,
review text and credentials never appear in the public projection.

Supported producer v1 `review-completion.json` commits the approved review and all validation/input
artifact bytes, exact repository/issue/source/base/scope, original receipt/delivery attempt,
reviewer run/thread/model/effort and parent worker/attempt. Its content identity uses recursively
sorted compact UTF-8 JSON with integer completion values. The original usage identity projection
is committed separately; accounting observation, tokens and debits are excluded. Delayed or missing
usage observation cannot change completion or establish earlier approval. Legacy receipts and
retained observation-only proof remain unknown without supported completion evidence.

GitHub ordering has separate clock provenance. `closure-ordering.json` binds that event to a new,
digest-only GitHub comment and the authenticated closed/reopened lifecycle captured before review.
The observer authenticates the exact comment again, including its issue, unchanged body and
creation/update timestamps; missing, edited, foreign or duplicate anchors supply no proof.
The current lifecycle must equal the captured prefix plus exactly one completed closure matching
the issue's current state, reason and `closed_at`. Anchor creation must be in an earlier GitHub
second than closure, and any prior lifecycle must precede the anchor. Same-second, equal,
fractional or missing v1 server timestamps remain ambiguous. Local completion/usage times,
file timestamps, elapsed durations and estimated clock offsets never order GitHub closure.

Operations joins the whole native review start/completion/accepted window to exactly one
prospectively tracked issue worker, preserving its original run ID, item attempt and budgets.
The completion must retain the original reviewer/parent identities; one reviewer run cannot own
multiple completion events. Native times identify complete one-second worker buckets independently
of the GitHub clock. Associations are immutable, closure-specific, idempotent across polls/restarts
and expire with their original worker history. Reopen preserves history; a later closure needs its
own completion and captured lifecycle. Only committed, freshly authenticated anchors demonstrably
before a reopen exclude old references; incomplete references keep the current closure ambiguous.

A scope fingerprint prevents later criteria edits from inheriting earlier report acceptance.
Conflicting scopes at the same GitHub timestamp remain unknown across replay/restart until a newer
observation resolves scope, even when lifecycle ordering rejects the conflicting observation.
The latest retained lifecycle stays intact. Lifecycle event IDs order reopen/closure observations
sharing an issue update timestamp; IDs are retained only when separately read issue state and
closure time match the timeline, allowing corrected reads after a race. Reusing a closure timestamp
cannot reuse earlier proof, including when a reopen is missed between polls.

Dispatch/terminal handoffs, canonical ownership, original attempt budgets and unmet scope remain
intact; a child report cannot accept its broader parent. Receipt polling adds no usage; auxiliary
review accounting retains its separate run-ID deduplication. This is repository-reported verification,
not independent acceptance. Verified cost, latency, delivery count and helper coverage stay unknown
until their own proof exists. Only bounded rejection codes are projected. See [the GH-72 investigation](report-verification-timing.md) for the
production reproduction, supported producer contract and real canonical closure verification.

## Canonical final-attempt handoffs (Crescendo extension)

An issue number is a dispatch identity, not authorization for a new outcome budget. Final-attempt
issue prompts append the canonical handoff contract. Keep one canonical root issue for the unmet
outcome, its source SHAs, unique evidence, acceptance dispositions and required native dependency
and capability edges. Diagnostics, investigations and unmerged PRs do not count as accepted progress.
Investigations and reduced slices can run within the existing bounded attempt policy. The root
ends delivered, explicitly declined with a reason, or retried within `max_item_attempts`.

Unchanged blockers reuse that root; do not create/promote ready replacements or reopen a declined
root without a changed prerequisite. Closed issue attempt budgets and retirement dispositions
survive polling and Operations restarts. Reopening a retired root does not repeat validation or
retirement. A blocked native prerequisite closed `not_planned` remains unsatisfied.

After accepted partial delivery or a newly completed external prerequisite, grooming can authorize
one fresh successor. Put the identical record in the closed canonical root's body and the new
successor's body (the root is the immutable `owner`; it cannot itself point to another owner):

```html
<!-- crescendo:handoff {"owner":123,"change":"partial_delivery","evidence":456,"scope":"Accepted fixture validity; exact production remainder remains required"} -->
```

`partial_delivery` requires a merged repository PR `evidence`, newer than the root's creation, with
an explicit closing line for that root. `scope` records the accepted slice and exact remainder;
the matching root record is grooming's acceptance authorization. A merged diagnostic PR alone is
not authorization. `prerequisite` instead requires the evidence issue to remain a native blocked-by
edge of the root, closed explicitly `completed` after the root's closure. Record owner-confirmed
external evidence on that prerequisite; a closed unaccepted prerequisite does not qualify.

GitHub validates the record during polling and dispatch refresh, including retry. Missing or
invalid proof fails admission closed. Legacy Markdown headings naming a `replacement of #N` or
`remainder from #N` also require the record; such an issue cannot name itself as the canonical owner
or authorize further successors as a new root. Ordinary incidental references are unaffected. The
budget is keyed by root, proof kind and native proof number, excluding editable prose. Operations
binds it to the first admitted successor; another issue number, wording edit, closure, restart or
replay of the proof cannot renew attempts. A held or otherwise unroutable successor cannot reserve
an unbound proof budget; holding an already bound successor preserves its binding. Worker blocked
markers still settle against that budget. Removing a bound successor's record cannot convert it
to unrelated work. Unrelated issues and PR budgets retain their existing behavior.

Running successors stop if authorization is removed or their proof is rebound. Restoring the original
authorization continues the same budget. Final-attempt throttling also uses that budget, so a
successor's last attempt retains the configured exception to the daily spending limit.

Closed PRs still clear their review runs, failed attempts and retirement markers so reopened PRs can
resume review. An exhausted open PR retries failed retirement writes on subsequent polls.

Admission is read-only at GitHub: rejected duplicates are not delivery owners and cannot trigger
blocked-marker consumption, validation workers or retirement (including draft closure). Their
bodies, PRs, labels and native edges stay intact for grooming to consolidate into the root. Before
any administrative supersession, grooming must preserve unique evidence on the root, add any
required native edges to the admitted successor before removing an old edge, and retain the root
edge as historical disposition. The service does not infer equivalent outcomes from arbitrary
prose or migrate historical chains automatically. Explicit holds and dependency owners remain
intact. The dashboard remains strictly read-only.

Local prompt deployment belongs to the operator. Replace any instruction to file ready replacements
on a final attempt with: “Reuse the canonical unmet-outcome owner. Unchanged blockers and diagnostic
evidence do not grant fresh attempts. Preserve required native edges, source and evidence there;
deliver an accepted reduced slice, explicitly decline the remainder, or use bounded retries. Only
grooming may admit one successor after verified accepted partial delivery or a newly completed
native prerequisite, using the matching `crescendo:handoff` record on root and successor.”
