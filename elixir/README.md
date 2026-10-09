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

Token accounting keeps one durable watermark and run allocations per native thread. Canonical
usage takes precedence over legacy notifications; input plus output determines spend tokens,
while cached input, cache writes, reasoning output and reported context figures remain separate.
The dashboard labels USD as an API-equivalent estimate. `usage.account_usage` reports native
estimate coverage; missing account billing, independent acceptance evidence and helper usage stay
unknown in `usage.delivery_metrics`.

Non-object Codex messages remain diagnostic summaries. Model/turn bookkeeping and optional
notification capture ignore malformed envelopes and fields without stopping project workers;
subsequent valid notifications still update usage, model reroutes and completion facts.

Two optional per-project settings support the [token-cache plan](docs/token_cache_optimization_plan.md):
`codex.resume_threads: false` and `codex.developer_instructions: null`. Their defaults preserve fresh
worker threads and existing instruction channels. Only local issue work within one logical attempt
can resume after an accounted, successful native turn; research and reviews always start fresh.
Changed task contracts, files, tools, policies, routes, storage, dates or native versions force a
fresh thread. Persistence failures prevent reuse. The supported schemas were checked for Codex
0.156.1 and 0.160.0; native wire/resume probes used 0.160.0 with fake credentials and a loopback
provider. SSH resumption remains disabled until remote checkout identity can be verified.


Issue worker delivery evidence survives completion and restart in Operations' retained lineage.
`usage.delivery_metrics.issue_associations` exposes explicit worker-owned sources, merge SHAs,
tracker observations, attempts and canonical outcome ownership. Reduced scope and retirement stay
distinct from repository-reported completion; missing proof stays unknown. Source creation must
identify a unique retained worker attempt. Canonical handoffs and split scope captured at dispatch
or terminal reconciliation survive tracker edits before the first delivery observation, including
removal of the record or label.
GitHub source ownership accepts a closing directive or an exact standalone `Symphony issue: #N`
line with the matching same-repository worker branch. Incidental mentions provide no ownership.
Malformed handoff evidence retained from closure keeps acceptance unknown after marker removal.
Canonical report-only `--verify-existing` closures use `repository_reported_verification`, with
`delivery_kind: report_only` and separate `report_verifications`, without a fabricated PR source.
A matching GitHub closure event and one exact-source canonical reference must agree with bounded
private closure/input/acceptance/review/validation receipts under the existing
`METALRAIN_SYMPHONY_EVIDENCE_ROOT`. An approved review and reviewer run/time must join one unique
retained issue worker; headings and successful turns alone cannot establish acceptance. Captured
scope must match the observed issue; a fingerprint prevents later criteria edits inheriting old proof.
Conflicting scopes at one GitHub timestamp stay unknown across replay/restart until a newer observation.
Wrong-source, wrong-issue, foreign, ambiguous or incomplete evidence remains unknown. The immutable association
survives closure/restart, preserves original attempt budgets and unmet parent scope, and expires
with the original worker. GitHub time precision is preserved; native times use one-second buckets.
Reopen retains evidence; a later closure needs its own proof. Canonical review timestamps exclude
pre-reopen references from the new closure's ambiguity check. Receipt polling
adds no usage, and existing auxiliary review run-ID deduplication stays separate from native workers.
Raw receipts and paths stay private. Historical runs without prospective tracking remain unknown;
independent acceptance and helper coverage remain unknown, so verified cost and latency stay null. See
[retained delivery evidence](../docs/crescendo.md#retained-issue-delivery-evidence) for the contract.

`developer_instructions` appends explicitly reviewed service-owned rules to existing configured
developer instructions. It preserves native base instructions. Do not move repository guidelines
or work-item content into this channel. No provider cache-key or boundary override is exposed.
Neither control is enabled by this deployment: deployed ChatGPT request traces, complete delivery
lineage and billing reconciliation are still needed before a live savings experiment.

New project templates include disabled defaults. Existing local workflows require a separate
reviewed migration; updating the generator does not change them. Controls are captured when a
worker starts so a workflow reload cannot change reuse behavior halfway through its run.

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
- `agent.max_attempts` optionally caps delivery failure retries. Once exceeded, the issue is blocked until
  its state or labels change. Unset means retry indefinitely with backoff.
- `codex.routing` optionally selects a model and reasoning effort from explicit issue labels.
  Example: `routing: {label_prefix: "symphony:model:", default: {model: "gpt-6.1-sol", effort: "medium"}, labels: {"symphony:model:astra": {model: "gpt-6.1-sol", effort: "xhigh"}}}`.
  With no matching route label, `default` applies. Unknown or conflicting labels under the
  prefix stop the run. Priority does not affect routing. A run keeps its selected route across
  continuation turns; a label change takes effect on a new run. Without `routing`, existing
  Codex command and account defaults continue to apply.
  Add `ladder` (routes from cheapest to strongest) and `escalation` (steps climbed per item
  attempt) to escalate retries: with
  `ladder` set to `gpt-6.1-sol` at efforts `low`, `medium`, `high`, `xhigh` and `max`, a `medium`
  default and `escalation: [0, 1, 2]`, attempts 1, 2 and 3 run at medium, high and xhigh.
  The default and every label route must be ladder steps; a label sets the starting step.
  `sizes` maps size names to starting routes picked by `size_label_prefix` labels (for example
  `sizes: {tiny: {model: gpt-6.1-sol, effort: low}, small: {model: gpt-6.1-sol, effort: low}}` with
  a `symphony:size:small` label). A model label wins over a size; a size keeps the `default` route
  label. `effort_floor` (for example `{gpt-6.1-sol: low}`) is the lowest effort a model may be
  configured at, checked for every route including research, review and channel routes.
- `labels.prefix` (default `symphony`) names the labels Symphony reads or applies itself unless
  set explicitly: `<prefix>:model:` and `<prefix>:size:` routing labels, `<prefix>:blocked`, and
  the `<prefix>:research` and `<prefix>:channel:<name>` labels on research runs. Tracker
  `required_labels` and `excluded_labels` stay explicit. The agent inspector hides labels in the
  selected project's prefix namespace before showing up to eight work labels.
- `throttle` limits what starts, never what is running:
  - `daily_budget_usd` enforces a daily (UTC) estimated spend. Over it, only the
    `over_budget_allow` classes start (default `[pull_request, final_attempt, continuation]`;
    the others are `issue` and `research`), so open work keeps closing while nothing new begins.
  - `backoff` rules act on a Codex quota window (`weekly`, `daily`, `5h`, ...):
    `{window: weekly, remaining_below_percent: 3, pause: true}` holds every new run until the
    window resets. `avoid: [<model>]` instead swaps a model for the strongest allowed ladder step
    (never below the item's own or the default start; with none allowed the run waits).
  - Quota older than `quota_stale_ms` (default two hours) or never seen counts as unknown;
    `on_unknown_quota: restrict` (default) still avoids models then but never pauses. A stale
    reading below a pause threshold still holds, so while the quota is stale or paused the service
    reads it straight from `codex app-server` every five minutes and resumes once the window resets.
  - Waiting on a slot or the throttle is never a failed attempt: a held retry keeps its attempt
    number and checks again every 30 seconds.
- `pricing` overrides or adds model prices for spend estimates and the budget:
  `{as_of: "2026-10-01", models: {gpt-6.1-sol: {input: 1.0, cached_input: 0.1, output: 5.0}}}` in
  USD per million tokens. Unlisted models keep the built-in prices.
- Every Codex run's environment carries `SYMPHONY_WORK_ITEM` (the work item identifier, such as
  `GH-12`) and, with routing, `SYMPHONY_SELECTED_MODEL_LABEL`. Commands the agent runs inherit
  both, so workstation tooling can attribute work to the run that owns it.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Workspace preparation (`after_create`, `before_run`) and cleanup (`after_run`) use
  `hooks.timeout_ms`, independently of `codex.stall_timeout_ms`. The orchestrator tracks worker
  phases; Codex inactivity starts when preparation finishes, including app-server startup.
  Startup request/response waits also retain `codex.read_timeout_ms`. Mandatory hook failures use the independent startup budget;
  cleanup failures are logged and ignored. Reloads preserve the current phase, and runtime restart
  cancels workers with their scheduler before redispatch.
- Due retries and retries held for admission stay in the service's weighted slot queue;
  future backoff does not reserve a slot. Retry timers refresh the slot policy before checking capacity.
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
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and read-only JSON
  API at `/`, `/api/v1/state`, and `/api/v1/<issue_identifier>`, plus run images at
  `/artifacts/<run_id>/<name>`. Use `GET /api/v1/state` to observe state; issue polling is automatic.
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
3. **Research on schedule.** Each `autopilot.channels` entry (task) runs when it is due, one at a
   time with the machine to itself: `idle` tasks when nothing is ready and no agent is running,
   `anytime` tasks whenever a slot is free. Each run
   (`prompts/research.md`; default channels `cleanup`, `optimization`, `testing`) builds, tests,
   benchmarks, and exercises the product headed, then files between `min_issues_per_channel` and
   `max_issues_per_channel` evidence-backed `symphony` issues. `autopilot.research_route` runs
   research on a stronger model than the default issue route, and `autopilot.review_route` fixes
   the model for pull request reviews. Tasks that file issues
   pause while `max_open_issues` are open; `research_cooldown_ms` is the default interval.
   A channel is its focus text or an object that can also carry its own prompt file, issue
   counts and route: `qa: {focus: "...", prompt: prompts/research/qa.md, min_issues: 2,
   max_issues: 4, route: {model: gpt-6.1-sol, effort: xhigh}}`. A channel's `min_issues` may be
   `0` when finding nothing is a valid outcome. Channels also take `every` and `when` (their own schedule),
   `effort`, `expectations` and `delivers`, and a repository's `.crescendo/autopilot/` folder can
   replace them with its own tasks and guidelines (see `docs/crescendo.md`). The shared research prompt is
   optional when every channel names its own.
   Without `at`, `every` is completion-based. With `at: "06:00"`, the next due time is the
   latest UTC 06:00 at or before completion plus `every` rounded up to calendar days (minimum one).
   A daily run finishing at 19:12 leaves tomorrow's 06:00 due; one finishing before 06:00 leaves
   today's anchor due. Sub-day intervals become daily and `36h` becomes two days. The first run
   is due at the latest anchor at or before now; delayed runs do not replay missed occurrences.
   Failed attempts still retry after 30 minutes. Running tasks cannot dispatch again, and tasks
   requiring a PR wait while an open PR (including drafts) carries their channel label.

Nothing is parked waiting for an operator. A worker that hits a blocker records it and adds
`symphony:blocked`; Symphony counts a failed attempt, clears the label, and retries the issue behind
other work. Exhausted crash retries and stops for operator input count the same way. The third
attempt (`autopilot.max_item_attempts`) is final: the worker delivers, splits and delivers, or closes
the issue, and if it still fails Symphony closes the issue as not planned along with its draft pull
requests. Pull requests that reach `max_pr_runs` without merging are closed too. Add `symphony:hold` to any issue or pull request
to stop and hold it. Handled pull request heads and the research cooldown survive restarts.

GitHub retirement closes only owned drafts: a body line starting with `Closes #N`, `Fixes #N`,
`Resolves #N` (including singular/past forms), `Symphony issue: #N` or `Crescendo issue: #N`,
or an `issue-N` branch segment with an optional hyphenated suffix. Dependency mentions, other
issue numbers and non-draft PRs do not establish draft ownership.

Startup failures before a session is admitted are an exception to delivery exhaustion: they retain
the issue and dependencies, retry twice after 10/20 seconds, then expose a startup block with a
30-minute recovery probe. Correct the environment and leave the item ready, or change the relevant
hooks/workspace/worker/Codex config to retry immediately. Backoff survives restart in the operations
store; successful admission clears it. They consume neither item effort nor PR review/research
attempts. Once admitted, even a zero-token model failure follows normal delivery policy. See
[the startup policy and recovery contract](../docs/crescendo.md#first-service). SSH workers running
hooks need GNU `timeout`; local and transport process groups are cleaned on cancellation.

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
  For a retrospective, request `/api/v1/state?history=full` (optionally `&project=<id>`) to read
  up to 2,000 events per selected project and 48 hours of five-minute samples. Check the oldest
  timestamps before claiming a complete cycle; daily totals and 14-day task averages keep their
  existing windows. The default API and dashboard show 100 events and 12 hours of samples.
- Five-minute samples also retain timestamped Governor capacity observations (`admission`), including
  shared held slots, deployment drains and global research phases. Unavailable and legacy observations
  stay null. Service history keeps one whole latest observation per bucket and independent
  `project_samples`; shared slots never sum. Partial buckets have unknown aggregate counts and are
  omitted from sparklines. Filtered counts describe selected projects only. The existing 48-hour
  durable retention and read-only/privacy boundaries apply. See the
  [capacity evidence contract](../docs/crescendo.md#dashboard-and-api) before attributing intervals.
- Dollar figures compare recorded tokens with standard short-context API prices dated
  September 24, 2026. They are estimates, not actual ChatGPT billing; unknown models remain
  unpriced. Recording starts with the first run after this version is deployed. The dashboard
  warns when estimated worker usage for the UTC day reaches `observability.daily_budget_usd`
  (default $50); separate planner and independent reviewer calls are not included, and the
  warning does not stop dispatch.
- The dashboard at `/` is built for phones first. Eight header stats carry sparklines: agents,
  queue, open pull requests (with a link to each project's pull request list on GitHub), pull
  request transitions today, runs done today, the 14-day turn completion rate, the average task cost and time,
  and spend today (from a five-minute sample of queue counts and spend kept for 48 hours in
  `operations.dets`). Below them are the 14-day runs and spend charts (with each model's and
  project's spend) and cards for system health, autopilot, model usage and per-task averages (cost
  and time per delivery, review, research and marketing task over 14 days).
  The work timeline runs the full height on the right: up next (retries and the ready queue with
  estimated start times, soonest nearest the middle, waiting items folded away), now (running
  agents) and done (finished runs, merges, closes and failures, newest first with their time and
  cost), each step with its own icon. The picture timeline shows the images agents captured, one
  card per run with the newest image large, as a full-height column on the left from 1600px and a
  film strip under the stats on narrower desktops. A wide window at least 900px tall fits the page;
  on phones Timeline, Pictures and Stats are tabs. Running agents sit in a strip under the cards,
  horizontal on wide screens and stacked on phones. The strip keeps one slot per
  worker (up to four empty ones), so its size holds steady; each agent card shows the plan's
  progress, a plain-language line for the latest step, the last thing the agent said, its latest
  image, and its model, tokens, cost and changed lines, and free slots show the next ready item.
  Queue estimates use the median run time of the same kind of work over the last three days, in
  waves of `agent.max_concurrent_agents`. Health checks report only signals Symphony observes:
  polling, dispatch capacity, blocked items, research, tracker and pull request read age and
  errors, rate limit use and failed attempts in the last hour, the usage store, and free workspace
  disk space.
- Service snapshots preserve every requested project's outcome: `projects[].snapshot_status`
  is `ok`, `timeout`, `unavailable`, or `not_selected` for a project outside the filter.
  Unobserved project running/ready counts are `null`. The selected aggregate has
  `snapshot_status: complete|partial` and a `snapshot_errors` list of project/status pairs.
  Partial snapshots keep observed rows and private-project redaction, set all aggregate `counts`
  to `null`, and show an incomplete warning and unknown counts instead of idle/free slots.
  Health warns on incompleteness; dispatch can still report Governor-held service slots without
  inventing running or queue counts. The next successful snapshot clears the warning.
  Service `throttle.draining` reports the deployment drain flag; `throttle.research_hold` is
  `null` or `{project, phase}` for a current global research reservation (`reserved`) or running
  hold (`running`). Expired reservations and project/none research are excluded. Dispatch health
  details explain these holds in full, filtered and partial views without changing admission,
  private-work redaction or unknown counts. These current signals do not backfill history.
  Deployment validators reject partial, filtered, or unknown project observations and unknown
  Governor-held slot counts. Routine deployment drains wait at most five minutes, then leave at
  least thirty minutes for dispatch before retrying busy work; newer candidates share the pause.
  Service issue workers yield after a successful native turn and checkpoint persistence when the
  Governor is draining, before starting another turn. Cleanup and slot release happen normally;
  an `interrupted` outcome with reason `deployment_drain` keeps source/workpad, logical attempt
  and retry count (including zero) intact. Existing scheduling resumes the issue after the drain,
  with native thread reuse still optional. Failed turns and checkpoint failures retain ordinary retry
  behavior; standalone workflows do not yield.
  Long in-progress turns keep their existing execution deadlines, so deployment is not guaranteed
  within one five-minute window. Unavailable observations still wait.
  Fully idle services deploy immediately after rechecking under the hold. The deployment journal
  records hold start/end, elapsed and sampled idle time, ready work and quota/budget restrictions.
  See [deployment policy](../docs/crescendo.md#install-and-deploy) for overrides and recovery.
  Deployment health also requires every enabled project's `tracker_ready` to be `true`: its
  Orchestrator has successfully polled active issues in this process generation with no subsequent
  poll/configuration error. Restart resets readiness even with persisted PR inventory; a failed
  poll clears it until recovery. Unavailable and unselected snapshots report `null`. Empty queues,
  quiet holds and slot counts stay separate; drain/helper accounting is unchanged. The existing
  24 health attempts (five seconds apart, ten-second HTTP timeout) allow startup polling and retain rollback.
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
  three days after it was last active. A private (`redact: true`) project's images never appear
  on the dashboard.
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


### Durable outcome facts

`operations.dets` preserves run endings separately from blocked item attempts and scoped delivery
or retirement. The dashboard's turn completion rate measures normal worker endings, not product
acceptance. Stopped workers retain their recorded duration/cost and are not classified as failures.
PR closes/reopens remain transitions, not abandoned deliveries.

Daily state API rows add `stopped`, `blocked_attempts`, `accepted_deliveries`, `retirements` and
`unknown_dispositions`. New attempt/disposition events retain their work item, attempt and last
recorded run ID; missing historical attribution is `unknown`. Counts cover the retained event ring;
durable idempotency keys survive restart. Keys for blocked attempts include run IDs, so resetting
the retry budget on PR reopening retains new attempts. Issue budgets persist across closure.
Plain issue closure has unknown acceptance.
For accepted issue work without a merged PR, apply `<prefix>:delivery:verified-existing` or
`<prefix>:delivery:split` after validation and document scoped evidence in the workpad; `not_planned`
is retirement. See [the detailed semantics](../docs/crescendo.md#durable-outcome-facts).

### Bounded Codex notification transport

Codex stdio input uses a 16 MiB frame assembly ceiling and a separate 4 MiB RPC/control
payload ceiling. Partial turn-frame assembly has an absolute `codex.read_timeout_ms` deadline
from its first fragment, while complete stream updates retain the configured silence timeout.
Ordinary notifications drain during RPC waits; tool/approval requests use their
normal handlers, and terminal/input events and startup cumulative usage remain in the bounded
control queue (4 MiB / 1,024 entries). Codex 0.160.0 generated schema excerpts are checked in under
`test/fixtures/codex-0.160.0-output-schema.json`. Diagnostic copies of supported text deltas,
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

Operations reconciles supported cumulative usage even after completion, failure, interruption or
force-stop. The existing 90-day run history retains credential-free attribution; late accounting
cannot act on a replacement worker or grant checkpoint eligibility. Run history and dashboard
summaries show corrected estimates and explicit `terminal_observed` / `incomplete` accounting.
Terminal observation is evidence of a matching cumulative snapshot and terminal turn, not a
promise of complete provider billing. Missing cache-write and helper/reviewer coverage stay unknown.
Observed turn usage evidence survives older notifications, including before turn-start responses.

The offline tests use the pinned Codex 0.160.0 schema and a synthetic sanitized reproduction of the
reported aggregate gap. Graceful teardown flushes supported queued events; force termination can
prevent observation. No new turn or token-usage RPC is used. See [reconciliation and coverage
limits](../docs/crescendo.md#terminal-thread-usage-reconciliation) before replaying copied native
records into an offline scratch ledger.

## Canonical final-attempt handoffs (Crescendo extension)

Final-attempt issue prompts append the [canonical handoff contract](../docs/crescendo.md#canonical-final-attempt-handoffs-crescendo-extension). Unchanged outcomes reuse
one canonical root and its bounded attempt budget. Closed issue attempts and retirement dispositions
survive polling and restarts; an issue number, diagnostic evidence or unmerged PR grants no renewal.
Investigations and accepted reduced slices remain possible within the bounded policy.

GitHub admits one successor only after matching authorization records on the closed root and successor,
verified merged partial delivery or a newly completed native prerequisite. Root plus native proof owns
the budget; proof replay cannot reset it. Running successors stop when authorization is removed or
rebound, and final-attempt throttling uses that same budget. Held or otherwise unroutable successors
cannot reserve an unbound proof budget; holding an already bound successor preserves its ownership.
Closed PRs still clear their review runs, failed attempts and retirement markers so reopened PRs can
resume review. An exhausted open PR retries failed retirement writes on subsequent polls.
Invalid and legacy unproven replacements fail admission closed without retiring their PRs or altering
evidence, labels, holds or native edges.
Required capabilities, dependencies and unique source/evidence must survive worker/groomer disposition.
A root ends delivered, explicitly declined, or retried within policy. Local prompt rollout remains
the operator's responsibility; the dashboard stays read-only. No arbitrary prose equivalence or
historical migration is inferred.
Legacy replacement headings prevent an issue from declaring itself a canonical root, including
when its record would otherwise authorize another successor.


### Shared helper and quiet acceptance policy

A service can keep three primary slots while adding up to five global read-only helpers.
Set `helpers: {slots: 5, model: gpt-6-luna, effort: max, timeout_ms: 900000}` in `crescendo.yml`;
helpers default to disabled. Leads receive `helper_start`, `helper_status` and `helper_cancel`.
A request names a bounded question and optional text evidence keys relative to the external
Metalrain evidence root. Read tools use the captured Git commit, reject replacement refs,
links and pathspecs, and bound source/evidence files to 128 KiB and returned text to 16 KiB.
The helper has no shell, edits, browser, apps, MCP, nested delegation or machine lease.
Its native JavaScript dispatcher calls only curated reads; native approval requests fail closed.
Inherited MCP servers are disabled through a nested `mcp_servers` map before native startup.
CLI map values use TOML inline tables, and thread configuration uses the same nested JSON map.
Literal server names preserve punctuation without creating extra dotted-path entries; existing
transport definitions remain intact with `enabled=false`. Invalid configuration fails closed.
Private, bounded catalogs in sealed anonymous memory remove model metadata that otherwise
forces patch/delegation capabilities; the user's catalog stays intact. The pinned CLI needs a populated model cache.
Helpers are supervised with a 15-minute absolute deadline, unique usage lineage and cleanup
when their parent ends. Cancellation retains capacity until the process stops.

Optional `quiet_window: {start: "03:00", end: "04:00", time_zone: America/Vancouver,
drain_minutes: 60}` reserves the recurring local window only while otherwise eligible
`<labels.prefix>:quiet` work is pending. The timezone follows installed IANA rules. Other
work yields at turn boundaries before the window, quiet tasks wait for the shared pool and
helpers to empty, and unfinished quiet work yields after the cutoff. Metalrain's measurement
command also requires `machine-lease run --quiet-window -- <foreground command>`.
Ordinary work remains available around the clock outside reserved windows.

An autopilot task may use `exclusive: none` for planning alongside delivery, or `exclusive: global`
for checks that need an idle machine. `skip_unchanged: true` compares fresh source, complete
open dependency/PR inventories, findings, configuration and protected execution state before
creating a workspace. Unknown inputs defer; unchanged inputs update only a check cursor,
never audit coverage, with a full recheck at least daily. Existing maintenance due rules apply.

The state API separates managed helper usage from `usage.external` CLI observations. External
review/planner reports have claimed identities and unknown account debits; they never affect
native run usage or budget enforcement. `pacing` projects consumption toward a soft 90% reset
window target with 10% interactive allowance. It reports uncertainty for stale/missing epochs
and preserves the daily budget and weekly quota pause.
