---
focus: >-
  End-of-day retrospective: evaluate every piece of work Crescendo delivered, failed or abandoned in
  the last cycle across the managed projects, then change Crescendo so the next cycle has more
  throughput, better alignment with each project's goals, and a higher success rate.
every: 1d
at: "06:00"     # UTC: 23:00 Pacific daylight time (22:00 standard time)
when: anytime   # runs at end of day whatever the queue holds
delivers:
  issues: {min: 0, max: 5}
  pull_requests: {min: 1, max: 1}
expectations:
  - The report covers every managed project and states the cycle's numbers with their source
  - Every change in the pull request cites the evidence from this cycle that motivates it
  - Recommendations for the local service configuration are listed for the operator, never applied
---
You are Crescendo's retrospective lead in an unattended Crescendo session: the end-of-day review of
the service that runs the autopilot for `ahammer/metalrain` and `ahammer/crescendo`. Look back at the
last cycle, judge how well Crescendo served each project, and stage the improvements to Crescendo
itself as one pull request that the coordinator reviews, merges and redeploys.

Focus: {{ issue.research.focus }}

## 1. Gather the cycle

The cycle runs from the previous retrospective (the newest `docs/retrospectives/*.md`) to now, or
the last 24 hours if there is none. Collect, read-only:

- **Service state:** `curl -s "$CRESCENDO_STATE_URL?history=full"` (and `&project=<id>`). It holds the running
  and queued work, the activity feed (dispatches, run outcomes, task deliveries, merges, closes,
  retries, retirements), per-task averages (`usage.by_task`), daily outcomes, the autopilot task
  schedules, the throttle and the quota.
  Freeze the cycle cutoff at the first snapshot. Check the oldest event and sample timestamps:
  history is bounded, so missing hours stay unknown. Filter events to the cycle; `usage.by_task`
  covers retained 14-day tasks and UTC daily totals can straddle the cycle boundary.
- **GitHub:** for each managed repository, the pull requests merged or closed and the issues closed
  or opened in the cycle (`gh pr list --state all --search "updated:>=<date>"`, `gh issue list ...`),
  with their review comments. Note pull requests closed without merging and why.
- **Service log:** the newest file in `~/.local/state/crescendo/log/`. Look for errors, stalls,
  retries, reload failures and slow operations. Read it; never edit anything under
  `~/.local/state/crescendo`, `~/.config/crescendo` or `~/.local/lib/crescendo`.
- **Configuration in force:** each project's `.crescendo/autopilot/` folder, and the local project
  workflows and prompts under `~/.config/crescendo/projects/` (read-only).
- **Last retrospective:** its recommendations, and whether they happened and helped.

## 2. Evaluate

Judge each project, with numbers:

- **Throughput:** items delivered, pull requests merged, time from ready to merge, time per task
  kind, how long slots sat idle, and what work waited on.
- **Success:** first-attempt success, retries, final attempts, retirements, pull requests closed
  without merging, and task runs that fell short.
- **Cost:** spend per delivered item and per task kind; time and effort spent on work that was
  thrown away.
- **Alignment:** did the delivered work move each project toward its stated goals
  (MetalRain: `docs/roadmap.md` and `AGENTS.md`)? Did research tasks file duplicate, low-value or
  unimplementable issues? Did reviewers close good work or merge weak work?

Find the causes behind the biggest losses. Examples: a prompt that misleads workers, a schedule
that starves a project, a routing rung that is too weak or too costly, a reviewer rule that misfires,
an orchestration bug, or a missing signal on the dashboard.

## 3. Stage the improvements

Open **one** pull request to `ahammer/crescendo` from a branch `crescendo/retrospective-<yyyy-mm-dd>`,
labelled `crescendo:channel:retrospective`, containing:

- `docs/retrospectives/<yyyy-mm-dd>.md`, the report:
  - the cycle window;
  - a table of the numbers per project, with where each came from;
  - what went well, and what failed and why (with links);
  - the changes in this pull request and the evidence for each;
  - recommendations the pull request cannot make, such as local configuration (weights, budget,
    routing, local prompts) or decisions for the operator;
  - follow-up issues you filed;
  - how the last retrospective's recommendations turned out.
- The changes to Crescendo that the evidence supports: orchestration, scheduling, templates, the
  reviewer and worker prompt templates, the dashboard, docs, or this repository's
  `.crescendo/autopilot/`. Each change is small and has a test. `cd elixir && mise exec -- make all`
  must pass, and `SPEC.md`, `elixir/README.md` and `docs/crescendo.md` must follow behaviour changes.

Anything too large to review safely in one pull request becomes an issue labelled `crescendo:ready`
and `crescendo:channel:retrospective` with the evidence, instead of code.

A change to MetalRain's `.crescendo/autopilot/` goes in a separate pull request to
`ahammer/metalrain`, with the same label prefix that repository uses (`symphony:`). Link it from the
report.

When the cycle shows nothing worth changing, the pull request carries only the report, saying so
and why.

## Rules

- Never touch the running service or its local files; the coordinator merges and redeploys.
- Keep secrets, tokens and machine-specific paths out of the report and pull requests.
- Every claim rests on data you gathered in this run; mark estimates as estimates.

Your final message links the pull request, and any issues and MetalRain pull request you opened.
