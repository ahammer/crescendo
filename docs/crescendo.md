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

Start the service with the service file instead of a `WORKFLOW.md`:

```bash
./bin/crescendo ~/.config/crescendo/crescendo.yml --logs-root ~/.local/state/crescendo \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

Project workflows and their prompt files hot-reload as before. Adding, removing or reweighting a
project, or changing the service file, needs a service restart. A project whose workflow cannot
load is reported on the dashboard (its filter pill is marked) and the other projects still run.

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
     postpones).
  3. It points `service.env` at the release and restarts the service.
  4. It waits for the state API to answer with every project started, and otherwise rolls back.

  A release that fails its gate or health check is not tried again. Each outcome is appended to
  `<state>/deploys.jsonl`, and the five newest releases are kept.

## Commands

These change local files, or a project's own repository through your `gh` login, never the
running service:

```bash
crescendo project add ~/.config/crescendo/crescendo.yml nubu3d ahammer/Nubu3D [--branch main] [--prefix crescendo] [--tools node@22,rust@1.82]
crescendo labels sync ~/.config/crescendo/crescendo.yml [nubu3d]
crescendo labels migrate ~/.config/crescendo/crescendo.yml metalrain --from symphony
crescendo drain on|off ~/.config/crescendo/crescendo.yml
```

- `project add` writes `projects/<id>/` (a `WORKFLOW.md`, a pull request review prompt and a research
  prompt) from the built-in templates. It never overwrites, and it prints the line to add under
  `projects:`. `--tools` puts mise tools in front of Codex, so the agent and everything it runs
  have them.
- `labels sync` creates every label a project's workflow uses that its repository lacks: ready,
  hold, in-review, blocked, one per research channel, sizes and model routes. It exits with an error
  if a requested project is unknown or GitHub cannot list or create the labels.
- `labels migrate` moves every open issue and pull request from each `<old>:` label to its twin under
  the project's `labels.prefix` (run `labels sync` first). Old labels stay for history. Runs get
  the prefix as `CRESCENDO_LABEL_PREFIX`, so repository tooling can follow the switch. It exits with
  an error if GitHub cannot list items or add/remove a label.
- `drain on` stops new runs; running work finishes. `drain off` releases it.

## `crescendo.yml`

```yaml
server: {host: 0.0.0.0, port: 4280}
paths: {state: ~/.local/state/crescendo}
pool: {slots: 3}
throttle:
  daily_budget_usd: 200
  backoff:
    - {window: weekly, remaining_below_percent: 40, avoid: [gpt-6-astra]}
    - {window: weekly, remaining_below_percent: 3, pause: true}
pricing: {as_of: "2026-10-01", models: {gpt-6-sol: {input: 1.0, cached_input: 0.1, output: 5.0}}}
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
    route: {model: gpt-6-sol, effort: xhigh}
```

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
- `/agents/<project>/<id>` is an agent's inspector.
- `GET /api/v1/state[?project=<id>]` is the merged state, with every item tagged by `project`.
- `GET /api/v1/<project>/<id>` is one work item.

There are no write routes.
