# Crescendo service

One Crescendo service runs several projects. Each project is a repository with its own
`WORKFLOW.md` (tracker, hooks, routing, autopilot, prompts), and every project shares the
service's worker slots, daily budget and Codex quota. Symphony's specification treats a
multi-project control plane as out of scope; this document describes Crescendo's.

Everything is configured in local files on the machine that runs the service. The dashboard and
the JSON API are read-only: nothing reachable over HTTP changes state.

## Layout

```
~/.config/crescendo/
  crescendo.yml                        # the service: slots, throttle, pricing, defaults, projects
  projects/<id>/WORKFLOW.md            # one project (the same schema as a single-workflow run)
  projects/<id>/prompts/...            # prompt files referenced from that WORKFLOW.md
~/.local/state/crescendo/              # state (paths.state)
  projects/<id>/operations.dets        # each project's run, spend and activity history
  quota.term                           # the last Codex quota snapshot
  drain                                # present while new dispatch is held for a deploy
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

## Install and deploy

`ops/install.sh` installs the scripts to `~/.local/lib/crescendo/bin` and the systemd user units.
It never enables a unit or overwrites local configuration.

- `bin/start` runs the service from the release `CRESCENDO_RELEASE` (in `service.env`) points at.
  `CRESCENDO_LOCK` names a lock that anything else must not share; `CRESCENDO_CODEX_VERSION`
  optionally pins codex.
- `bin/crescendo` runs a command (below) with the deployed release, from any directory.
- `bin/deploy`, run by `crescendo-deploy.timer` every 10 minutes, deploys the newest `main`:
  1. It builds `releases/<sha>` and passes the full `make all` gate under the machine lease.
  2. It drains, so no new runs start and running ones finish (it waits up to two hours, then
     postpones). Unknown or partial snapshots keep the drain waiting; Governor-held slots also
     prevent an empty observed running list from ending the drain. Unknown held-slot counts
     keep the drain waiting too.
  3. It points `service.env` at the release and restarts the service.
  4. It waits for a complete, unfiltered state response with every project started, no project
     failure, every project snapshot `ok`, and known Governor-held slot counts; otherwise it
     rolls back.

  A release that fails its gate or health check is not tried again. Each outcome is appended to
  `<state>/deploys.jsonl`, and the five newest releases are kept.

The service's read-only state API and dashboard mark each project's snapshot as `ok`, `timeout`,
`unavailable`, or `not_selected` (outside the filter). Unknown running/ready counts are `null`.
The selected aggregate reports `snapshot_status: complete|partial` and `snapshot_errors` with
project/status pairs. Partial reads preserve observed work and private-project redaction, but
aggregate `counts` are `null`, health warns and the dashboard shows unknown counts. Governor-held
service slots can still be shown; they do not imply a queue count. A successful read clears the
warning. `ops/bin/deploy-state.py` validates deployment observations independently of the deploy
script; it only reads JSON from stdin and never accesses or restarts the service.

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
- `drain on` stops new runs; running work finishes. `drain off` releases it and reports an error if
  its flag cannot be removed.
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
- **Drain.** While `<state>/drain` exists, nothing new starts; running work finishes normally. Deploys
  use this.

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
    at: "06:00"        # optional time of day (UTC) the task runs at, every `every`
    when: idle         # idle: only when nothing else runs or waits; anytime: whenever a slot is free
```

Each channel (task) runs on its own schedule; the most overdue due task goes first. After a run,
Crescendo counts the issues and pull requests it opened with its `<prefix>:channel:<name>` label.
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

- `/` shows every project; `/?project=<id>` filters to one.
- `/agents/<project>/<id>` is an agent's inspector. It omits the project's configured `labels.prefix`
  and every `<prefix>:` label before showing up to eight work labels. Single-workflow inspectors use
  that workflow's prefix (default `symphony`); an open inspector keeps its last resolved prefix if
  configuration becomes unavailable.
- `GET /api/v1/state[?project=<id>]` is the merged state, with every item tagged by `project`.
- `GET /api/v1/<project>/<id>` is one work item.

There are no write routes.


## Durable outcome facts

The existing Operations DETS ledger separates three observations:

- Run endings (`completed`, `failed`, `stopped`, `interrupted`) measure worker transport/turn
  completion, with wall time and recorded API-equivalent cost. A completed turn is not acceptance;
  stopping an accepted worker during reconciliation is not failure. Duplicate endings preserve the
  first ending and its time/cost.
- `attempt_failed` (or `blocked` without autopilot) measures a blocked item attempt, independently
  of its run ending. New facts retain the work item, item-attempt number and last recorded run ID.
  The durable item/attempt/run key prevents duplicate counting while distinguishing new attempts
  after a closed item reopens and its retry budget resets.
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
