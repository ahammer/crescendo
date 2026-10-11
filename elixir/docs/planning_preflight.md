# Planning evidence identity and rollout

The orchestrator owns preflight identity and a persisted contract version. Version changes
invalidate older baselines. It hashes source, complete tracker/PR state,
evidence, delivery protection/capacity and configuration separately. Persisted component digests
contain no paths or evidence text. Admission durably invalidates the old baseline before worker
creation, so a crash/restart cannot reuse interrupted work. A verified task completion establishes a baseline; failed,
short, interrupted and unverified runs clear skip eligibility while keeping their existing
attempt/backoff rules. Legacy digest baselines require one new run. Reload/restart preserve new
baselines. Skips advance only the cheap cursor, never evaluation completion or audit coverage;
the full task is revisited after 24 hours.

## Producer contract

`METALRAIN_SYMPHONY_EVIDENCE_ROOT` is read only. When configured, missing, malformed or oversized
root inputs, missing referenced reports and unknown schemas defer worker startup. Each JSON read
is bounded to 4 MiB. With no evidence root configured, the other native inputs still apply.
An unavailable configured planning ledger or a failed baseline write/sync also defers admission.

Existing `autopilot/maintenance/latest.json`, `cost-state.json`, referenced findings, adjacent
`ci-cost.json` and grooming dispositions retain their substantive handoff schema. Producers may
add `preflight_schema: 1` and move **confirmed observation-only metadata** into a top-level
`preflight_observation` object. Every root and referenced document must opt in; mixed/legacy
cohorts keep strict identity, including paths. Unknown versions or observation field names defer.
Unknown substantive fields remain identity inputs.

The observation bucket accepts only string/null bookkeeping values under these field names:

```text
observed_at updated_at started_at finished_at resumed_at groomed_at
run_key observation_key disposition_key report_key report_sha256 ci_cost_key ci_cost_sha256
consumed_report_sha256 consumed_ci_cost_sha256 grooming_report_key grooming_report_sha256
last_observation_key last_resume_observation_key last_grooming_observed_at
```

These are bookkeeping values, not a way to hide policy or coverage. In particular, keep the actual
`last_completed.finished_at` due anchor, source/build/environment/policy identities, checks and
outcomes, findings/retained findings, publication (including pending work), dependencies, holds,
selected issues, capacity flags, acceptance blockers and quiet-window comparison status in the
substantive document. Nested publication observation timestamps may be moved to the
bucket as a string under their bookkeeping field name; preserve the publication disposition itself. Do not
move whole records or histories that contain substantive state into this bucket.

Loader pointers stay in their existing locations: `latest.report_key`,
`latest.pending_report_key`, `latest.grooming_disposition_key`, `costs.last_completed.report_key`,
`costs.pending.report_key`, `costs.pending_evaluation.report_key`, `costs.completed_report_key`,
`costs.grooming_disposition_key`, and `costs.last_resume_grooming_disposition_key`. After every
referent is read successfully, identity replaces these paths with the document's substantive
content **at the same role**. Swapping pending and completed evidence is not equivalent. Other
keys/links remain substantive unless moved under the explicit observation contract. Referenced
findings still require their adjacent cost report. No blocked delivery or pending coverage is removed.

This is a coordinated operator recommendation, not an installation migration performed by this PR:
update the local maintenance and grooming producer prompts together, retain the existing handoff
fields, and write the opted-in cohort atomically (reports before root pointers). A partial rollout
is conservative. Validate against the scrubbed `test/fixtures/planning/cycle.json` replay first.
Observation-only rounds must preserve substantive documents; when uncertain, leave a field
substantive. The legacy retained cycle alone cannot demonstrate savings from this new schema.

## Execution drain and pending coverage

Execution drain means no eligible execution is running, queued for execution or holding capacity;
it does not mean all selected findings are accepted. Fourteen retained selections waiting on
native prerequisites may coexist with an execution drain. Keep pending coverage and dependencies
recorded even then. Maintenance must separately require native prerequisites, its cost policy and
the confirmed quiet window before authorizing expensive checks. An unchanged preflight skip,
`0 issues / 0 PRs`, or an empty execution queue is never proof the quiet performance gate passed.
This contract does not change the scheduler's quiet admission or the machine lease policy.

## Bounded normal-traffic canary

After deployment and coordinated producer rollout, observe one project for **24 hours or twelve
paired grooming/maintenance due checks**, whichever comes first. Use normal traffic and existing
GET state/history APIs; do not dispatch extra tasks, alter timers/models or force heavy checks.
Cap helpers at two during observation. Compare with a preceding equally bounded normal-traffic
window; record start/end UTC, deployed revision and whether schema rollout was complete.

At each due check retain only scrubbed fields from the project state response with `history=full`:
`usage.planning`, preflight and terminal events' time/identifier/run ID/summary/seconds/estimated micro-USD,
`usage.by_task` for an aggregate research cross-check,
and task completion/check cursors. `usage.planning` counts retained skipped/admitted/deferred
checks; events distinguish `source`, `tracker`, `evidence`, `protection`, `configuration`,
`contract`, `daily_revisit` and `no_verified_baseline`. No evidence contents or local paths enter these events.
Count each due observation once. Counters are bounded retained history, not lifetime totals;
event eviction or unavailable snapshots make the interval incomplete, not zero activity.

Report checks, skips, admissions by reason, deferrals, actual task runs, timed-run coverage,
worker seconds and API-equivalent estimated micro-USD from terminal events for
`research-grooming` / `research-maintenance` (join by run ID; deduplicate accounting updates).
Category/model totals include other research channels and are only an aggregate cross-check. Include
interrupted/unverified runs, missing duration/cost coverage and late accounting corrections.
Skips consume zero worker seconds and start no model; do not assign guessed avoided API cost.
For matched unchanged cohorts compare observed planning worker-minutes and estimates between
windows, while reporting source/tracker changes separately. Do not claim all nineteen historical
rounds would have been avoided.

Stop the rollout if unchanged opted-in cohorts repeatedly admit on `evidence`, if pending state
vanishes, if a failed/unverified run skips, or if heavy checks are authorized outside existing
policy. Investigate the bounded reason privately and restore strict legacy identity by removing
the opt-in markers as a cohort. A live canary remains an operator follow-up after merge; this
isolated-clone PR validates the replay, not production savings.
