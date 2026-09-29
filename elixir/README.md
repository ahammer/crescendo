# Crescendo (Elixir)

This directory contains Crescendo, an Elixir/OTP implementation of Symphony based on
[`SPEC.md`](../SPEC.md) at the repository root. To run several projects from one service, see
[`docs/crescendo.md`](../docs/crescendo.md); everything below also applies to each project's
`WORKFLOW.md` there.

> [!WARNING]
> Crescendo is prototype software intended for evaluation only and is presented as-is.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub Issues serves `github_api`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/ahammer/crescendo
cd crescendo/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/crescendo ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Burrito releases

Crescendo's release workflows build self-contained executables with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it publishes a rolling `nightly` prerelease with binaries
and checksums. Nightly binaries use a `-nightly` version suffix; the release notes identify the
source commit. Stable releases remain unchanged.

Download a platform build from [Crescendo Releases](https://github.com/ahammer/crescendo/releases).
If no suitable artifact is published, follow the [source build steps above](#run).

After downloading a published executable for your platform:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## Configuration

Pass a custom workflow file path to `./bin/crescendo` when starting the service:

```bash
./bin/crescendo /path/to/custom/WORKFLOW.md \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Starting the service requires `--i-understand-that-this-will-be-running-without-the-usual-guardrails`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- `tracker.excluded_labels` is optional. An issue with any configured label (for example
  `symphony:hold`) does not dispatch, and a running worker stops when one is added.
- `agent.max_attempts` optionally caps failure retries. Once exceeded, the issue is blocked until
  its state or labels change. Unset means retry indefinitely with backoff.
- `codex.routing` optionally selects a model and reasoning effort from explicit issue labels.
  Example: `routing: {label_prefix: "symphony:model:", default: {model: "gpt-6-sol", effort: "medium"}, labels: {"symphony:model:astra": {model: "gpt-6-astra", effort: "high"}}}`.
  With no matching route label, `default` applies. Unknown or conflicting labels under the
  prefix stop the run. Priority does not affect routing. A run keeps its selected route across
  continuation turns; a label change takes effect on a new run. Without `routing`, existing
  Codex command and account defaults continue to apply.
  Add `ladder` (routes from cheapest to strongest) and `escalation` (steps climbed per item
  attempt) to escalate retries: with
  `ladder: [{model: gpt-6-sol, effort: medium}, {model: gpt-6-sol, effort: xhigh}, {model: gpt-6-astra, effort: medium}, {model: gpt-6-astra, effort: max}]`
  and `escalation: [0, 1, 3]`, attempts 1, 2 and 3 run on sol medium, sol xhigh and astra max.
  The default and every label route must be ladder steps; a label sets the starting step.
  `sizes` maps size names to starting routes picked by `size_label_prefix` labels (for example
  `sizes: {tiny: {model: gpt-6-luna, effort: max}, small: {model: gpt-6-luna, effort: max}}` with
  a `symphony:size:small` label). A model label wins over a size; a size keeps the `default` route
  label. `effort_floor` (for example `{gpt-6-luna: max}`) is the lowest effort a model may be
  configured at, checked for every route including research, review and channel routes.
- `labels.prefix` (default `symphony`) names the labels Symphony reads or applies itself unless
  set explicitly: `<prefix>:model:` and `<prefix>:size:` routing labels, `<prefix>:blocked`, and
  the `<prefix>:research` and `<prefix>:channel:<name>` labels on research runs. Tracker
  `required_labels` and `excluded_labels` stay explicit.
- `throttle` limits what starts, never what is running:
  - `daily_budget_usd` enforces a daily (UTC) estimated spend. Over it, only the
    `over_budget_allow` classes start (default `[pull_request, final_attempt, continuation]`;
    the others are `issue` and `research`), so open work keeps closing while nothing new begins.
  - `backoff` rules act on a Codex quota window (`weekly`, `daily`, `5h`, ...):
    `{window: weekly, remaining_below_percent: 40, avoid: [gpt-6-astra]}` swaps Astra for the
    strongest allowed ladder step (never below the item's own or the default start; with none
    allowed the run waits), and `pause: true` holds every new run until the window resets.
  - Quota older than `quota_stale_ms` (default two hours) or never seen counts as unknown;
    `on_unknown_quota: restrict` (default) still avoids models then but never pauses.
  - Waiting on a slot or the throttle is never a failed attempt: a held retry keeps its attempt
    number and checks again every 30 seconds.
- `pricing` overrides or adds model prices for spend estimates and the budget:
  `{as_of: "2026-10-01", models: {gpt-6-sol: {input: 1.0, cached_input: 0.1, output: 5.0}}}` in
  USD per million tokens. Unlisted models keep the built-in prices.
- Every Codex run's environment carries `SYMPHONY_WORK_ITEM` (the work item identifier, such as
  `GH-12`) and, with routing, `SYMPHONY_SELECTED_MODEL_LABEL`. Commands the agent runs inherit
  both, so workstation tooling can attribute work to the run that owns it.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`, plus run images at
  `/artifacts/<run_id>/<name>`.
- `observability.daily_budget_usd` (default `50`) is the estimated daily worker spend at which the
  dashboard raises its usage alert when no enforced `throttle.daily_budget_usd` is set.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: use `tracker.kind: github` with required `tracker.provider.repo` in `owner/repo` form,
  optional `token` (defaults to `GITHUB_TOKEN` and accepts `$VAR`), and optional `api_url`
  (default `https://api.github.com`, HTTPS only). Set explicit `active_states` and
  `terminal_states`; active entries may be `open` and terminal entries may be `closed`.
- Reads and identity: polling is scoped to the configured repository; `issue.id` is the
  repository issue number, `issue.identifier` is `GH-<number>`, hidden or transferred `404` issues are
  omitted on refresh (stopping their worker), issues deleted on GitHub (`410`) refresh as `closed`
  so reconciliation stops their worker and cleans their workspace, and pull requests returned by the Issues API are not dispatchable unless
  autopilot is enabled (see below).
- Native issue dependencies are checked for label-eligible open issues during polling and again
  on ID refresh before dispatch. An open blocker or one closed as `not_planned` prevents dispatch;
  a dependency API error fails the read rather than treating the issue as unblocked.
- Tool and auth: `github_api` accepts a relative REST `path` plus optional `params` and JSON
  `body`; Symphony executes it host-side with the session-bound token, removes configured tracker
  credentials and provider authentication aliases from the Codex child, and leaves raw tool access
  limited by that token's GitHub permissions.

### Autopilot (GitHub)

`WORKFLOW.autopilot.md` turns Symphony into a loop that keeps improving one GitHub repository:

1. **Pull requests first.** Open, non-draft pull requests become work items (`PR-<number>`).
   Authors whose `author_association` is in `autopilot.trusted_associations` or whose login is in
   `autopilot.trusted_authors` are admitted automatically; anyone else's pull request waits until
   a maintainer adds every `tracker.required_labels` label. A reviewer run
   (`prompts/pull_request.md`) reviews, pushes fixes when it can push to the head branch, and
   squash-merges pinned to the reviewed head commit once CI is green. Symphony skips pull requests
   whose CI is pending and re-reviews after a new push or, at an unchanged head, after
   `autopilot.pr_recheck_ms`, up to `autopilot.max_pr_runs`. The last run is flagged
   `final_attempt` so the reviewer merges or closes the pull request itself.
2. **Issues next.** Issues labeled `symphony` are implemented. The worker opens a pull request that
   closes the issue, then labels the issue `symphony:in-review`, which hands it to step 1.
3. **Research when idle.** When nothing is ready and no agent is running, a research round runs each
   `autopilot.channels` entry in turn, one at a time with the machine to itself. Each run
   (`prompts/research.md`; default channels `cleanup`, `optimization`, `testing`) builds, tests,
   benchmarks, and exercises the product headed, then files between `min_issues_per_channel` and
   `max_issues_per_channel` evidence-backed `symphony` issues. `autopilot.research_route` runs
   research on a stronger model than the default issue route, and `autopilot.review_route` fixes
   the model for pull request reviews. Research pauses while
   `max_open_issues` are open and for `research_cooldown_ms` after a round's last channel ends.
   A channel is its focus text or an object that can also carry its own prompt file, issue
   counts and route: `qa: {focus: "...", prompt: prompts/research/qa.md, min_issues: 2,
   max_issues: 4, route: {model: gpt-6-sol, effort: xhigh}}`. The shared research prompt is
   optional when every channel names its own.

Nothing is parked waiting for an operator. A worker that hits a blocker records it and adds
`symphony:blocked`; Symphony counts a failed attempt, clears the label, and retries the issue behind
other work. Exhausted crash retries and stops for operator input count the same way. The third
attempt (`autopilot.max_item_attempts`) is final: the worker delivers, splits and delivers, or closes
the issue, and if it still fails Symphony closes the issue as not planned along with its draft pull
requests. Pull requests that reach `max_pr_runs` without merging are closed too. Add `symphony:hold` to any issue or pull request
to stop and hold it. Handled pull request heads and the research cooldown survive restarts.

```bash
GITHUB_REPO=owner/name GITHUB_TOKEN=... mise exec -- ./bin/crescendo \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.autopilot.md
```

The token needs to read and write issues, pull requests, and contents, and to merge. `gh` must be
authenticated on the worker host for the workspace clone hook.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`
- The dashboard shows open issues from the last tracker poll in dispatch order, including those
  waiting on labels, dependencies, or operator attention, and (for GitHub trackers) an independently
  refreshed, read-only inventory of open pull requests.
- A local `operations.dets` file beside the rotating log keeps model usage and the latest 2,000
  lifecycle events across restarts. `/api/v1/state` exposes these as `usage`, `upcoming`, and
  `pull_requests`; a failed poll leaves the last good inventory visible with its timestamp and an error.
- Dollar figures compare recorded tokens with standard short-context API prices dated
  September 24, 2026. They are estimates, not actual ChatGPT billing; unknown models remain
  unpriced. Recording starts with the first run after this version is deployed. The dashboard
  warns when estimated worker usage for the UTC day reaches `observability.daily_budget_usd`
  (default $50); separate planner and independent reviewer calls are not included, and the
  warning does not stop dispatch.
- The dashboard at `/` is built for phones first. Five header stats carry sparklines: agents,
  queue, open pull requests, pull requests closed today (merged or closed without merging, over
  14 days) and spend today (from a five-minute sample of queue counts and spend kept for 48 hours
  in `operations.dets`). Below them are panels for system health and autopilot, 14-day runs, spend
  (with each model's spend today and over 14 days) and model usage. Then come the work queue with
  estimated start times, pull requests and recent activity. On a desktop window at least 1200px
  wide and 900px tall the page fits the window, and these lists stretch to fill the height above
  the agents; on phones the sections are tabs showing one at a time. Running agents sit in a strip
  at the very bottom, horizontal on wide screens and stacked on phones. The strip keeps one slot per
  worker (up to four empty ones), so its size holds steady; each agent card shows the plan's
  progress, a plain-language line for the latest step, the last thing the agent said, its latest
  image, and its model, tokens, cost and changed lines, and free slots show the next ready item.
  Queue estimates use the median run time of the same kind of work over the last three days, in
  waves of `agent.max_concurrent_agents`. Health checks report only signals Symphony observes:
  polling, dispatch capacity, blocked items, research, tracker and pull request read age and
  errors, rate limit use and failed attempts in the last hour, the usage store, and free workspace
  disk space.
- An agent card opens the full-screen agent inspector at `/agents/<issue_identifier>`. It shows the
  agent's run as a chat, rebuilt from Codex app-server notifications: messages and reasoning
  (streamed as they are written), commands with exit code, duration and the last 60 lines or 8 KB of
  output, file edits with diffs, plan steps, and images inline where the agent saw them. Beside the
  chat (or behind tabs on phones) are the plan, changed files, an image gallery and run details.
  Symphony keeps the last 150 entries of each running agent in memory; when a run ends while its
  inspector is open, the last live view stays on screen, and `/api/v1/<issue_identifier>` serves
  the transcript while the run lasts.
- Images the agent viewed or generated, and images returned by tools such as screenshots, are
  copied into `artifacts/<run_id>/` beside the log file (PNG, JPEG, GIF or WebP only, up to 10 MB
  each and 40 per run) and served at `/artifacts/<run_id>/<n>.<ext>`. A run's images are deleted
  24 hours after it was last active.
- The dashboard is read-only, but it shows raw agent output and images. Anyone who can reach it
  sees everything agents print or look at, so only expose it where that is acceptable.
- Setting `SYMPHONY_NOTIFICATION_CAPTURE_DIR` records the raw app-server notifications that feed
  transcripts (with long strings shortened) as one JSON-lines file per run, for protocol debugging.

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in GitHub Issues live test with a disposable/scratch repository:

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the [Crescendo repository](https://github.com/ahammer/crescendo),
which is based on [OpenAI's Symphony](https://github.com/openai/symphony), and ask it to set things
up for you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
