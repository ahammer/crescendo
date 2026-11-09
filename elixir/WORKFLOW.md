---
# Generic Linear compatibility example. Edit the project slug and export CRESCENDO_TARGET_REPO.
# For GitHub, prefer `crescendo project add`; see ../docs/crescendo.md#first-service.
tracker:
  kind: linear
  provider:
    project_slug: REPLACE_WITH_YOUR_LINEAR_PROJECT_SLUG
  active_states: [Todo, In Progress]
  terminal_states: [Closed, Cancelled, Canceled, Duplicate, Done]
polling: {interval_ms: 30000}
workspace: {root: ~/.local/share/crescendo/workspaces/linear-demo}
# Optional: evidence: {root: ./evidence} resolves next to this workflow.
hooks:
  after_create: |
    set -eu
    : "${CRESCENDO_TARGET_REPO:?Set the Git clone URL of your target repository}"
    git clone --filter=blob:none "$CRESCENDO_TARGET_REPO" .
agent: {max_concurrent_agents: 1, max_turns: 20}
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  resume_threads: false
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy: {type: workspaceWrite, writableRoots: [], readOnlyAccess: {type: fullAccess}, networkAccess: true}
---

Work on {{ issue.identifier }}: {{ issue.title }}.

{{ issue.description }}

Read the repository's README, AGENTS.md and contribution instructions when available. Confirm the
problem, implement the smallest complete fix, and run the repository's documented checks. Respect
its build and hardware resource rules. Keep a concise workpad on the issue with the plan, evidence
and blockers. Open a pull request for operator review; do not assume an automatic reviewer exists.
Use the configured tracker's states and repository delivery conventions. Preserve existing work
when continuing an earlier attempt.

Before handing a PR to the operator, move the ticket to your team's review state outside
`tracker.active_states`; adapt the state names above to your team. Do not mark it Done before
operator acceptance.
