# Token-cache optimization for Crescendo

Status: implementation authorized; measurement and guarded reuse are implemented. Live optimization experiments remain gated.

Evidence inspected on October 2, 2026. No implementation, deployed configuration changes, GitHub issues or pull requests, or billable agent experiments are authorized by this document alone.

## 1. Evidence and success criteria

Optimize **account usage and elapsed time per independently reviewed, merged PR**. Include implementation, retries, review, failed work, and attributable research. Cache-hit ratio remains a diagnostic.

The inspected checkout is `ahammer/crescendo` at **`88070cdc61ecfea807774d857dc73df04632e209`**, with existing uncommitted dashboard, documentation, and test changes. The deployed release points to **`4d2e98dc06a972eaecc3f3e782993c9f89232342`**. Its accounting and orchestration include additional outcome correlation and deduplication; implementation must preserve those shipped behaviors.

Important observations:

- The service startup pin says Codex **`0.156.1`**, but recent service rollouts record **`0.160.0`**. Workers launch an unversioned `codex` command. Metalrain’s hook checks a different installed executable, which does not establish the version subsequently launched.
- Generated app-server schemas were inspected for both versions, alongside official OpenAI source tagged `rust-v0.160.0`.
- The live snapshot at `2026-10-02T22:58:31Z` reported **311.85 million input tokens**, including **306.30 million cached tokens**, for approximately **98.22% cached input** that day.
- One ongoing research app-server turn had accumulated over **28 million input tokens**. Its rollout later contained **197 provider usage records and two compactions**. One app-server turn can contain many model requests.
- The dashboard’s approximately **$41.59** daily figure is a ledger estimate using placeholder API prices. Available authentication evidence indicates ChatGPT authentication.
- Read-only `account/usage/read` queries succeeded for two existing service threads, but both returned **`threadUsage: null`**. Account credits and verified charges remain unavailable.

These observations establish neither delivery-level savings nor a reliable monetary baseline.

## 2. Architecture and verified Codex contract

### Current execution and accounting path

| Stage | Current behavior and consequence |
|---|---|
| Project configuration | Per-project runtimes load service defaults and local `WORKFLOW.md`. Local settings retain routing, budgets, and trust policy. Projects share Governor admission, quota, and weighted service slots. |
| Repository instructions | `RepoAutopilot` mirrors default-branch `.crescendo/autopilot/` files. Active repository task definitions can replace local research channels; guidelines reach every prompt. Workflow reload retains the last valid configuration on failure. |
| Selection and routing | Orchestrator revalidates eligibility, labels, dependencies, trust, and PR readiness. ModelRouting selects model and effort from labels, size, logical attempt, fixed research/review routes, and quota backoff. Its `tier` is a ladder index, **not provider service tier**. |
| Prompt construction | PromptBuilder strictly renders the selected template into one string, then appends research deliverables, PR task scope, and literal repository guidelines. Templates commonly place identifiers, titles, descriptions, or channel details before shared instructions. |
| Worker preparation | AgentRunner creates or reuses an isolated work-item workspace, runs creation and execution hooks, selects one host for its lifetime, and captures the tracker tool binding. Local and SSH workers use the same lifecycle. |
| Codex startup | AppServer launches Codex, initializes the protocol, and always calls `thread/start`. It passes workspace, model, policies, and dynamic tools. It currently retains the thread ID but discards effective settings returned by Codex. |
| Execution and continuation | `turn/start` receives one text input containing the whole Crescendo prompt. Codex executes native tools; Crescendo handles bound dynamic tools. Issue continuation uses the same thread and a short follow-up prompt. Research and review are single-pass runs. |
| Completion and redispatch | Closing a worker closes its app-server process. Subsequent dispatches create fresh threads, including normal continuation redispatches, failures, and service restarts. Retry metadata retains workspace/host information, not resumable conversation state. |
| Accounting and dashboard | Orchestrator computes positive deltas from cumulative usage using counters attached to the active run. Operations persists run/date/model aggregates in per-project DETS, prices them, and supplies dashboard snapshots. Transcript is bounded, in-memory display history and cannot reconstruct a native thread. |

The source and test map below identifies the concrete owners of a future change. Paths refer to the inspected checkout, not the deployed release.

| Owner | Entry points and relevant verification |
|---|---|
| [Service](../lib/symphony_elixir/service.ex), [ProjectRuntime](../lib/symphony_elixir/project_runtime.ex), [Workflow](../lib/symphony_elixir/workflow.ex), and [Config](../lib/symphony_elixir/config.ex) | Per-project configuration, workflow-store reload, and validated settings. Extend the schema and configuration assertions in [core tests](../test/symphony_elixir/core_test.exs); retain [service tests](../test/symphony_elixir/service_test.exs). |
| [RepoAutopilot](../lib/symphony_elixir/repo_autopilot.ex) and [WorkflowStore](../lib/symphony_elixir/workflow_store.ex) | Mirror manifest/blob changes, task overrides, literal guidelines, last-good-state recovery; [repo-autopilot tests](../test/symphony_elixir/repo_autopilot_test.exs). This HTTP mirroring is configuration loading, not the cache optimization. |
| [Orchestrator](../lib/symphony_elixir/orchestrator.ex) and [ModelRouting](../lib/symphony_elixir/model_routing.ex) | Dispatch authorization, `spawn_issue_on_worker_host`, worker updates, reconciliation, retry scheduling, and immutable dispatched review head; [orchestrator status tests](../test/symphony_elixir/orchestrator_status_test.exs), [routing tests](../test/symphony_elixir/model_routing_test.exs), and dispatch/retry cases in core tests. |
| [PromptBuilder](../lib/symphony_elixir/prompt_builder.ex) | `build_prompt`, strict Solid rendering, `append_sections`: template → deliverables → task scope → guidelines. Test rendering and source precedence in core and repo-autopilot tests before changing roles or order. |
| [AgentRunner](../lib/symphony_elixir/agent_runner.ex) and [Workspace](../lib/symphony_elixir/workspace.ex) | Workspace creation/hooks, `run_codex_turns`, same-session `do_run_codex_turns`, short `build_turn_prompt`, tracker refresh, host affinity, and teardown. Core tests exercise continuation and workspace lifecycle. |
| [AppServer](../lib/symphony_elixir/codex/app_server.ex), [DynamicTool](../lib/symphony_elixir/codex/dynamic_tool.ex), and tracker adapters | Initialize → `start_thread` → `start_turn` → approval/tool/notification receive loop → `stop_session`; [app-server tests](../test/symphony_elixir/app_server_test.exs) cover fake protocol streams, tools, policies, and failures. |
| [Operations](../lib/symphony_elixir/operations.ex) | `start_run`, `usage`, `finish_run`, per-item aggregates, DETS reopen/pruning, snapshots, and pricing; [operations tests](../test/symphony_elixir/operations_test.exs). Preserve deployed outcome deduplication when reconciling revisions. |
| [Transcript](../lib/symphony_elixir/transcript.ex), [Presenter](../lib/symphony_elixir_web/presenter.ex), and [ServiceSnapshot](../lib/symphony_elixir_web/service_snapshot.ex) | Bounded display/capture, project aggregation, dashboard/API presentation; [transcript tests](../test/symphony_elixir/transcript_test.exs), [service-snapshot tests](../test/symphony_elixir/service_snapshot_test.exs), and [redaction tests](../test/symphony_elixir/redaction_test.exs). Transcript capture truncates content and is not a complete request trace. |

Two lifecycle gaps need explicit treatment before adding reuse. The run ID is currently created after the worker is spawned and is not carried in its update messages; updates identify only the work item. Also, `AppServer.handle_response` ignores notifications received while awaiting an RPC response, so startup/resume usage can be lost. Future changes must allocate and pass the run ID before spawning and preserve those notifications with bounded buffering and bounded response waits.

**Configuration provenance must remain explicit:**

- Repository defaults, bundled workflows, and `elixir/prompts/` describe repository-provided behavior.
- `elixir/priv/templates/project/` generates new project files. `project add` does not overwrite existing projects.
- `.crescendo/autopilot/` supplies repository-owned tasks and guidelines.
- Local deployed workflows contain project-specific policies, hooks, and prompts that differ from the generators. Generator updates require separate, reviewed migration diffs for existing projects.

The repository-owned instructions currently include `autopilot.yml`, `guidelines.md`, and `tasks/retrospective.md`. Generated project workflows and research/review/marketing prompts are separate files under `priv/templates/project/`; the bundled workflow and `prompts/research.md` / `prompts/pull_request.md` are another source. Record each source's content hash and its rendered output hash independently. A source edit may affect new dispatches after reload without changing an existing native conversation; that must invalidate incompatible checkpoints.

### What Codex adds

Recent native rollouts show Codex-generated developer context—including skills, permissions, collaboration instructions, and plugin context—followed by user context containing AGENTS instructions and environment details, then Crescendo’s task prompt.

Workspace-specific skill paths appear early in the developer context. Thus task-specific material can precede otherwise-shared Crescendo instructions. Reordering Crescendo’s user string cannot change that earlier context.

The local model catalog advertises Responses Lite. In the inspected version’s request builder, that path prepends serialized tools and native base instructions to conversation history; the other path sends base instructions and tools through top-level request fields. Actual final wire requests still need capture. [Version-pinned request construction](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/client.rs)

| Integration point | Verified capability and limit |
|---|---|
| `thread/start` | Supports `developerInstructions`, `baseInstructions`, model, provider, policies, dynamic tools, and service tier. Replacing native base instructions is unnecessary and unsafe for this optimization. |
| `developerInstructions` | The inspected source places supplied developer instructions before generated skill context within the initial developer bundle. This changes instruction priority and does not create an explicit cache boundary. |
| `turn/start` | Supports effort and service-tier settings. The `title` currently sent by Crescendo is absent from both inspected schemas; it is not evidence of early model-visible text. |
| Input boundaries | Multiple text elements are converted into one user message. Splitting the prompt across text elements does not establish separate messages or cache boundaries. |
| `thread/resume` | Supports native resumption by thread ID. It does not accept replacement dynamic-tool specifications. Cloud-specific history/path injection fields must not be used. |
| History inspection | Both inspected schemas support `thread/turns/list` with `limit`, `sortDirection`, and `itemsView`, and `thread/resume.excludeTurns`. Inspect the last native terminal turn before reuse; exclude returned turn bodies when full history is unnecessary. |
| Configuration and capabilities | `config/read` supports `cwd` and `includeLayers`; `skills/list` supports workspace selection and forced reload; `mcpServerStatus/list` is paginated. These inspect configuration/discovered capabilities, not necessarily the exact model-visible tool serialization. |
| Usage | `thread/tokenUsage/updated` reports cumulative `total` and recent `last` usage. Native resume restores prior totals. Fields include cache writes and reasoning output, which Crescendo currently omits. |
| Completion | `turn/completed` carries a terminal turn whose status can be completed, failed, or interrupted. Crescendo currently treats this method as success without inspecting that status. |
| Account usage | `account/usage/read` accepts `threadId` and can return credit estimates and optional USD estimates. Availability was not established for this deployment. |

These controls are grounded in the generated schemas and [version-pinned context assembly](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/session/mod.rs). The inspection generated schemas under `/tmp/crescendo-codex-0.156.1-schema` and `/tmp/crescendo-codex-0.160.0-schema`; these are temporary artifacts, not repository dependencies. Regenerate them with the matching binary's `codex app-server generate-json-schema --experimental --out <directory>` before implementation, and inspect `ThreadStartParams.json`, `ThreadResumeParams.json`, `TurnStartParams.json`, and `GetAccountTokenUsageResponse.json` under `v2/`.

The current [official app-server documentation](https://developers.openai.com/codex/app-server/) is a reference for lifecycle and schema generation; the matching executable's generated schema governs each integration. Treat fields marked experimental accordingly, and keep a version mismatch visible instead of silently assuming latest documentation applies.

Codex derives its ordinary cache key and ChatGPT cache-affinity header from session identity. Crescendo has no verified public override for this. Responses cache options, retention, breakpoints, and prewarming are also absent from the inspected request builder and app-server controls. Free-form `config` or client metadata must not be treated as arbitrary Responses parameter forwarding.

Current provider documentation describes model-dependent cache boundaries and controls. An identical text prefix alone does not establish a usable boundary or cross-thread reuse. Explicit control of those boundaries or cache grouping would require supported upstream Codex changes. [Official prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching)

For GPT-5.6 and later, that guide describes message-ending implicit boundaries, a minimum of 1,024 visible tokens, and explicit content-block breakpoints. Top-level instructions cannot hold an explicit breakpoint. Codex can aggregate the supplied developer text and varying native context into one message; a stable fragment inside it may therefore lack a reusable boundary. These public API rules are a verification hypothesis for the deployed Codex/ChatGPT transport, not proof of its behavior. [Cache boundaries](https://developers.openai.com/api/docs/guides/prompt-caching#how-caching-works-gpt-5-6-and-later)

### Request-verification procedure

Before enabling either optimization, produce a small, local evidence bundle for each worker executable/version and provider route:

1. Record the actual launched executable's resolved path, version and hash on the selected host, initialize response, native storage identity, authentication mode without credentials, and matching generated schemas. A rollout's creation version alone does not establish the version executing a resumed thread.
2. Capture effective `config/read` layers, startup/resume settings and instruction-source paths. Record requested versus resolved model, effort, service tier, summary/verbosity settings, policy, feature flags and plugin/MCP configuration. Check per-turn overrides and provider-returned settings; mark unobservable settings unknown.
3. Use an isolated native Codex process with synthetic tasks, fake credentials, a loopback provider stub and blocked external provider egress. Test two distinct work items and two turns of one item; vary one path, date, policy, skill, tool setting or route at a time. A fake app-server validates Crescendo's RPCs, while this native fixture validates serialization. Neither establishes production cache hits.
4. Reconstruct complete requests, including any WebSocket deltas. Compare base instructions, developer-message grouping and ordering, AGENTS/skill context, cwd/workspace roots, execution policy, dates/timezone, ordered tool definitions, task text, and conversation history. Record the first divergent token/block and which eligible cache boundary precedes it. Check fresh start, native resume and compaction separately.
5. Verify the request's actual cache mode, grouping/affinity and usage semantics against version-pinned source and official provider rules. A `cwd`, title or work-item identifier passed to RPC or process environment is not evidence of its placement in model text. Provider-visible fields and headers must be observed directly.

Do not promote common text to developer priority or migrate production prompts until instruction-preservation tests pass and the shared prefix has a verified usable boundary. If no supported Crescendo-only interface can provide that boundary, propose an upstream Codex change with a versioned app-server contract instead of passing arbitrary Responses parameters through `config` or `turn/start`.

## 3. Proposed implementation

### Establish trustworthy measurement first

Reuse Operations, existing events, native rollouts, and dashboard snapshots.

- Record the worker executable/version, schema version, effective model/provider/effort/service tier, policy fingerprints, ordered tool-definition fingerprints, workflow/template revisions, and instruction-source fingerprints. Capture settings returned by startup/resumption rather than assuming the requested route was served.
- Fence worker updates with **run ID and thread ID**. Updates from an old worker must never accrue to a newly dispatched run for the same issue.
- Normalize cumulative usage by thread. Prefer canonical notifications; retain a version-specific legacy fallback without counting both. Remove the generic completion-usage assumption described in [token-accounting guidance](token_accounting.md).
- Preserve input, cached input, cache-write input, output, and reasoning-output fields. Reasoning output is a subset of output, not an additional charge. Keep context estimates separate from spend.
- Store the cumulative watermark and its run/date/model allocations together in one durable thread record. Derive aggregates from that record so restart replay remains idempotent. Check persistence errors explicitly for resumable state.
- Process startup/resume usage notifications and reconcile historical totals to their previous owner before counting new work.
- Add delivery lineage linking issue attempts, writer threads, independent reviewer threads, reviewed head SHA, merge outcome, and research outputs. Preserve deployed outcome deduplication. Worker completion and generic merge counts are insufficient acceptance evidence.
- Expose account-usage coverage, cost basis, accepted-delivery cost, end-to-end latency, and diagnostic token counts as additive dashboard/API fields. Preserve existing redaction.

Use supported thread account-usage reads when available. Store their cumulative estimates once per thread and replace refreshed snapshots rather than adding them repeatedly. Missing estimates remain unknown.

Keep API-equivalent USD separately labeled and use verified, versioned rates. ChatGPT credit billing has no separate cache-write charge; API billing differs. Quota percentages are operational gauges, not additive per-task charges. Billing reconciliation must establish which basis applies before claiming savings. [Official Codex pricing](https://learn.chatgpt.com/docs/pricing)

The durable accounting key must include project and native thread/storage scope, with allocations identified by run, date and effective model. An unchanged cumulative snapshot adds zero; a lower or missing counter must not reset the watermark. A later cache/reasoning classification must preserve subset totals without adding parent input/output again. Account for historical corrections separately when their exact run attribution cannot be proven. Old DETS records must remain readable and must not also be counted through a newly imported thread watermark.

Delivery lineage must record first observed eligibility, logical attempts and worker runs, issue-to-PR links, writer/reviewer thread identities, dispatched and actually reviewed head SHAs, verified merge head/time, and attributable research outputs. Retain cohort facts beyond run pruning. A channel label plus creation-time window currently proves only an association, not exact research causation. A completed review run or an unpinned merge event does not prove independent acceptance. Until these links and helper/child-thread billing coverage are available, expose acceptance cost/latency as unknown with explicit coverage counts.

### Cross-task reuse: controlled prompt experiment

Add optional **`codex.developer_instructions`**, default `nil`, to local workflow configuration.

- Move only explicitly reviewed, service-owned static operating rules into this field. Keep work-item text, repository AGENTS/guidelines, generated constraints, retry details, and reviewer-specific task content in their existing channels.
- Read effective Codex configuration through supported `config/read` before startup. Preserve existing configured developer instructions when composing the approved additions; preserve managed instructions and native base instructions.
- Remove migrated duplicate text from the corresponding task templates. Make serialization deterministic and keep required tools and their existing order.
- Verify that the resulting shared prefix has an eligible cache boundary and is reusable under the actual provider/session behavior **before enrolling this arm in a live experiment**.
- If the boundary or grouping prevents reuse, defer that arm to upstream support rather than changing workspace paths, removing environment information, or padding prompts.

Include reviewed generator and bundled-prompt changes only after this experiment demonstrates benefit. Prepare individual migration diffs for deployed Crescendo and Metalrain prompts; preserve their custom policies.

### Within-task reuse: native resumption at confirmed boundaries

Add **`codex.resume_threads`**, default `false`, using native `thread/resume`.

Eligibility is limited to **issue delivery within the same logical attempt**, following a confirmed successful terminal turn. Research occurrences and all PR review dispatches continue to receive fresh threads.

Persist a checkpoint containing:

- Project and stable work-item identity, logical attempt, thread ID, last confirmed turn, and usage watermark.
- Worker host, native storage identity, workspace generation, executable/version, effective route and policies.
- Task-contract, instruction-source, and ordered-tool fingerprints, including the captured tracker binding.

Before starting each turn, durably mark the checkpoint **in flight**. After confirmed successful completion, mark it eligible again. A worker that disappears during execution must not resume automatically from an earlier checkpoint.

Claim/invalidate a stored checkpoint before spawning the next worker, even if that dispatch chooses a fresh thread. Fence checkpoint writes by current run and native thread; a delayed prior worker must not overwrite a new worker's state. Capture reuse settings at worker startup so a configuration reload cannot skip an in-flight write or enable reuse halfway through a run. On service restart, unresolved active runs remain uncertain and cannot reuse their earlier eligible checkpoint.

On eligible redispatch:

1. Revalidate tracker authorization and run the existing workspace hooks.
2. Verify scope, workspace generation, native history availability, policies, instructions, route, and tool compatibility.
3. Resume by thread ID, reconcile restored usage, and append concise current continuation guidance.
4. Preserve existing attempt, turn, timeout, quota, admission, and cleanup limits.

Use a fresh thread after host failover, recreated/reset workspace, changed task contract or policies, incompatible tools/version/route, missing history, or uncertain execution state. Preserve workspace/workpad recovery. Storage failure disables resumption for that work item.

Workspace validation must occur after preparation hooks and cover both generation and the current checkout, including detached HEADs, packed refs and worktree gitdirs. Missing identity evidence means fresh startup. Rehash loaded instruction files and captured tracker binding; a discovered tool set is insufficient evidence of unchanged persisted dynamic tools or model-visible ordering. Resume must preserve native tool specifications and their binding, and native history inspection must confirm that no external turn superseded the saved successful boundary.

Inspect `turn.status` before declaring success or writing a resumable checkpoint. Remove the unsupported turn `title` parameter during the protocol update; retain its information in the task text and operational metadata.

For the inspected modern schemas, require the terminal notification's thread ID and turn ID to match the active turn. A child or foreign thread's completion cannot finish the parent. Failed, interrupted and missing/unknown status must follow existing failure/retry handling. Drain and reconcile restored usage before authorizing the first new action; protocol ordering must be verified, not inferred from RPC response timing.

Resumption may increase chargeable cached history while avoiding repeated reasoning and output. Its benefit must be measured, not inferred from restored conversation or cache hits.

## 4. Verification, experiments, and rollout

### Offline verification

Extend the existing ExUnit and fake app-server harnesses; add no new test framework.

Cover:

- Canonical/legacy duplicate usage, restored totals, missing fields, cache writes, reasoning subsets, stale worker updates, and compaction context estimates.
- Thread reuse across runs and service restart without duplicate spend; new-thread counters starting independently.
- Failed/interrupted terminal statuses, lost checkpoint writes, in-flight crashes, corrupt history, host failover, workspace recreation, and configuration reload.
- Persisted dynamic-tool compatibility and tracker binding across resumption.
- Fresh reviewer threads for every review dispatch/head; no writer history reaches reviewers.
- Strict rendering, literal guidelines, instruction precedence, generator compatibility, and preservation of deployed custom prompts.
- DETS reopen/migration, outcome deduplication, account-usage null handling, and dashboard redaction.

Use version-pinned Codex fixtures or a loopback provider stub with fake credentials and blocked provider egress to inspect full serialization without billable inference.

During later authorized normal work, use Codex’s existing opt-in **`CODEX_ROLLOUT_TRACE_ROOT`** facility at a capped sample rate. It records local request/response payloads. Reconstruct WebSocket deltas and distinguish logical request history from transmitted payloads. Retain sensitive bundles locally for seven days; publish only derived measurements. [Version-pinned trace facility](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/rollout-trace/README.md)

The trace review must establish instruction ordering, workspace/date/policy changes, exact tools and ordering, effective settings, provider boundaries, native resume behavior, and compaction effects.

### Proposed natural-work experiments

Run separately, in order:

1. **Measurement-only baseline**, including billing coverage and frequency of eligible redispatches.
2. **Issue resumption**, with prompt roles unchanged.
3. **Trusted developer rules**, only after payload/boundary verification passes.
4. Consider a separate native-compaction experiment only if evidence shows accumulated context dominates cost. Keep compaction defaults through the first three stages.

Start with the Crescendo project. Assign natural work deterministically by project and stable issue ID; keep all attempts of a delivery in one arm. Keep model routing, effort, service tier, scheduling, admission, and review gates fixed. Stratify results by project, route, work kind, context length, cache age, restart, and compaction.

Use fourteen days of enrollment and fourteen days of outcome follow-up, aiming for at least thirty accepted PRs per arm. Preserve cohort facts beyond ordinary fourteen-day run pruning. Insufficient samples or billing coverage produce an **inconclusive** result.

Primary measurements:

- Account usage per accepted PR, including failed/closed/retired work, retries, independent reviews, and linked research.
- Time from first observed eligibility to independently reviewed merge, including queueing and CI.
- Project-wide research overhead, counted once; prorate shared overhead between arms by enrolled work-item count.

For each arm, calculate cost per accepted delivery as **all enrolled work's attributed account usage divided by its independently reviewed, matched-head merged PR count**. Include abandoned and still-open work in the numerator; a zero denominator is undefined. Separate directly linked research from the remaining shared overhead before prorating so neither is counted twice. Measure latency for the same delivery cohort, and report unresolved work/censoring and acceptance rate alongside median and p95. Thirty accepted PRs is a proposed minimum, not a power calculation; set practical improvement and regression thresholds from the baseline before enrollment.

Diagnostics include provider time to first token, request count, uncached/cached/write input, output, compactions, and weighted `Σ cached input / Σ input`. Do not divide same-day spend by same-day merges or treat completed runs as accepted deliveries.

Promote only when delivery-level analysis shows a credible reduction in account usage and median completion time, with no p95 latency or acceptance-quality regression. Use delivery-level confidence intervals, not individual model requests as independent samples. Any isolation, review-independence, duplicated-action, or restart-reliability violation stops the experiment.

Run targeted checks, then the repository's required `make all` and applicable contract checks. Roll out telemetry first, followed by disabled-by-default optimization controls. Disabling a control returns subsequent dispatches to fresh-thread behavior while preserving historical accounting.

### Implementation order and completion gates

| Increment | Files/owners | Completion gate |
|---|---|---|
| Reconcile baseline and capture protocol provenance | AppServer, configuration, versioned offline fixtures | Preserve uncommitted user work and shipped outcome behavior; identify actual local/SSH binaries; establish request/context ordering without billable inference. |
| Normalize, fence and durably attribute usage | Orchestrator, AgentRunner, Operations, token-accounting documentation | Restart replay is idempotent; canonical/legacy events cannot double count; historical usage never bills a new run; missing billing and attribution remain unknown. |
| Record delivery lineage and measurement coverage | Operations, existing tracker/pull inventory, Presenter/ServiceSnapshot/Redaction | Accepted deliveries require independently reviewed, matched-head merge evidence; retries and research are included once; cohort retention and private-project redaction pass. |
| Add disabled native resumption | Configuration schema, AgentRunner/AppServer, Orchestrator checkpoints | Same-attempt issue reuse only; interruption/reload/storage/history/tool/host/checkout tests pass; reviewers and research remain fresh; operational limits remain intact. |
| Add disabled trusted developer additions | Configuration schema and AppServer; reviewed prompt edits later | Existing developer/managed/base instructions are preserved; task/repository input cannot enter the shared trusted block; verified boundary and grouping permit the experiment. |
| Prepare migration and rollout | Bundled workflow, generator templates, docs, separate diffs for each deployed local workflow | Required repository checks pass; controls default off; existing projects receive explicit migration diffs; experiment and rollback criteria are ready before activation. |

At the planning handoff, this document did not authorize creating those changes,
migrations or experiments. The later implementation authorization is recorded in
section 6. If accounting or lineage gates fail, continue improving measurement;
do not enable reuse or claim savings based on a higher hit ratio.

## 5. Defaults and missing evidence

Defaults are native base instructions, isolated workspaces, fresh independent review, existing routing and operational limits, no additional prewarming, and no cached model answers. Existing project configuration requires explicit migration; generator changes alone are insufficient.

Evidence still required before claiming production improvement:

- Final provider request traces and actual cache boundaries/grouping for deployed workers.
- Consistent executable provenance and effective request settings across local and SSH hosts.
- Account credits, quota attribution, or verified charges reconciled to service-owned threads, including any child or external helper usage.
- Complete delivery/research lineage and independently reviewed merge evidence.
- Delivery-level cost, latency, and quality baselines with adequate billing coverage.

At the planning handoff, all changes and experiments above were proposals. No
token-optimization implementation changes remained from that planning task.
Existing workspace changes were retained; deployed configuration was unchanged,
and no token-cache GitHub issues/PRs or billable agent experiments were launched.


## 6. Implementation and deployment record

The user subsequently authorized implementation and deployment. The implementation
starts from upstream main at `b089f48` in an isolated worktree,
leaving the original checkout's dashboard changes untouched. The historical revision
and deployment evidence above remain the planning baseline, not a claim about the
new release.

Implemented: event-specific usage normalization (including native
`cacheWriteInputTokens`), atomic thread watermarks and run allocations, replay-safe
restored usage, source precedence, stale-run fences, successful native terminal
status/ID validation, bounded startup notification retention and RPC deadlines,
durable issue checkpoints, optional native resumption and additive developer
instructions, native account-estimate coverage, retained run/head/merge/research
observations, and explicit API-estimate labels. Flags default to disabled/null.

Reuse requires a complete canonical usage snapshot for the saved terminal turn.
Checkpoints are claimed before dispatch and invalidated before every turn. Local
workspace/Git identity, tracked diffs, untracked files, native instruction and skill
files, effective configuration, discovered MCP capabilities, tracker/task contract,
route, version, native storage and UTC date must match. Missing evidence starts a
fresh thread. SSH reuse is deliberately deferred because local filesystem checks
cannot attest a remote checkout. Reviews and research never reuse checkpoints.

Native probe evidence on October 2, 2026 used the installed Codex **0.160.0**,
a temporary native home, fake credentials, a loopback Responses provider and a
proxy that denied attempted external GitHub/ChatGPT connections. Three synthetic
requests showed common instructions followed by AGENTS/environment context and
task text; continuation retained the earlier messages. The native request contained
`prompt_cache_key`, session/thread headers and eight ordered tools; a second thread
had a different cache key. After process restart, `thread/turns/list` returned the
saved completed turn and `thread/resume` emitted its cumulative usage before the
read barrier. This verifies the ordinary Responses path only. Deployed ChatGPT/
Responses Lite grouping, cache boundaries, latency and billing remain unverified.
No billable model was invoked.

The verified executable is the installed immutable standalone release at
`/home/adam/.codex/packages/standalone/releases/0.160.0-x86_64-unknown-linux-musl/bin/codex`,
SHA-256 `12eb3e81114588aca3b7998f4f19e8997b056aca08e57a7ca7c8a3ec8c652aad`.
Existing local project commands and the service startup version check are migrated
explicitly to this executable; generated project templates alone would not align
them. This alignment does not enable either reuse control.

Delivery cost and latency remain **unknown**. Retained observations include first
eligibility, run/attempt identity, requested routes, native thread links, dispatched
review heads, GitHub merge heads/times, and research output associations. An observed
merge, completed reviewer run or channel/time association does not establish the
full writer/issue/independent-review lineage. Helper/child-thread cost coverage is
also unknown. These are explicit remaining measurement gates, not zero-cost data.

The rollout enables telemetry and correctness fixes with both reuse controls off.
Production prompt migration, lower turn limits, compaction tuning, savings claims,
and billable experiments require the evidence and experiment gates in sections
2–5. Generator defaults do not modify existing deployed project configuration.

Validation: the required `make all` passes, including 516 tests with zero failures
(six existing live/environment tests skipped), reported 100% coverage, formatting,
public-function specifications, lint and Dialyzer. Native probe evidence validates
supported schema fields and process-restart usage restoration without provider
billing; it does not demonstrate production cache hits or savings.
