---
# Autopilot: Symphony continuously improves one GitHub repository.
#
# Priority order on every poll:
#   1. Open pull requests (external or Symphony's own) from trusted authors:
#      review, push fixes when possible, and merge once CI is green.
#   2. Open issues labeled `symphony`: implement, open a PR, hand off to (1).
#   3. Nothing ready: one research run per channel files new `symphony` issues.
#
# Run with GITHUB_REPO=owner/name and a GITHUB_TOKEN that can push, label,
# comment, and merge. `gh` must be authenticated for workspace clones.
tracker:
  kind: github
  provider:
    repo: $GITHUB_REPO
    token: $GITHUB_TOKEN
  required_labels:
    - symphony
  # `in-review` hands an issue to its PR; `hold` is the operator kill switch
  # for issues and pull requests alike.
  excluded_labels:
    - symphony:in-review
    - symphony:hold
    - symphony:needs-attention
  active_states: [open]
  terminal_states: [closed]
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-autopilot-workspaces
hooks:
  after_create: |
    gh repo clone "$GITHUB_REPO" . -- --filter=blob:none
agent:
  max_concurrent_agents: 4
  max_turns: 20
  max_attempts: 3
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
autopilot:
  enabled: true
  # Research channels: name -> what that planner hunts for by running the product.
  channels:
    cleanup: >-
      Code and API quality found by building, running, and tracing real behavior: dead or duplicated
      code, unclear ownership and names, awkward or inconsistent APIs, error handling that hides
      failures, and code that is hard to read or change.
    optimization: >-
      Measured performance, memory, and resource costs found by running benchmarks, profilers, and
      timed product journeys, plus latent bugs exposed along the way. Every claim carries numbers.
    testing: >-
      Behavior the tests do not prove, found by running the suite and exercising the product headed:
      failing, flaky, or slow tests, untested owners and edge cases, and user-visible defects seen in
      UI journeys, screenshots, and recordings.
  min_issues_per_channel: 3
  max_issues_per_channel: 5
  # Planning is the hardest judgment call in the loop; give it the strongest model.
  research_route: {model: gpt-6-astra, effort: high}
  # Research pauses while this many `symphony` issues are open.
  max_open_issues: 15
  research_cooldown_ms: 1800000
  max_pr_runs: 5
  # PR authors whose code may run and merge without a maintainer label.
  # Anyone else's PR needs every `required_labels` label added by a maintainer.
  trusted_associations: [OWNER, MEMBER, COLLABORATOR]
  trusted_authors: []
  prompts:
    pull_request: prompts/pull_request.md
    research: prompts/research.md
---

You are implementing GitHub issue `{{ issue.identifier }}` in an unattended Symphony autopilot session.

{% if attempt %}
This is follow-up attempt #{{ attempt }}. Resume from the current workspace state; do not redo finished work.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Rules

- Work only in this repository copy. Never ask a human for help; there is no one watching.
- Keep the change small and focused on the issue. File a new issue labeled `symphony` for anything out of scope instead of expanding this one.
- Use the `gh` CLI or the `github_api` tool for all GitHub reads and writes.

## Flow

1. Sync with the default branch and create or reuse the branch `symphony/{{ issue.identifier | downcase }}`.
2. If a pull request for this branch already exists and is open, continue it. If it was closed without merging, start over on a fresh branch.
3. Reproduce or confirm the problem before changing code.
4. Open a **draft** pull request early whose body includes `Closes #<issue number>`.
5. Implement the change with tests. Run the repository's validation (lint, tests) until green.
6. Push, then mark the pull request ready for review and add the `symphony` label to it.
7. As your very last action, add the `symphony:in-review` label to the issue. This hands the work to a separate reviewer run, which merges the pull request and thereby closes the issue.

## Abandoning

You may abandon the issue when it is blocked, wrong, not worth doing, or already fixed:

- Close any draft pull request you opened, with a comment explaining why.
- Close the issue as `not planned` with a short comment explaining the blocker or reason.

Your final message must list completed actions and any blocker only.
