# Canonical report timing investigation (GH-72)

On 2026-10-10, the canonical MetalRain receipts linked from #1245, #1247 and #1168
passed the source/scope, approval, clean-source, unchanged-input, failure-adjudication
and hosted-source inspection described in [Crescendo GH-72](https://github.com/ahammer/crescendo/issues/72).
Their retained usage observation timestamps nevertheless follow GitHub closure:

| MetalRain issue | Usage observation (2026-10-09 UTC) | Completed closure (UTC) | Ordering failure |
| --- | --- | --- | --- |
| #1245 | 09:38:07.429 | 09:35:57 | observation 130.429 seconds after closure |
| #1247 | 08:46:06.545 | 08:43:55 | observation 131.545 seconds after closure |
| #1168 | 11:11:29.623 | 11:09:18 | observation 131.623 seconds after closure |

Before this change, `GitHub.Client.read_report` assigned `review-usage.json.observed_at_epoch`
to `reviewed_s`. With a matching worker window, `Operations.retain_report_verification`
rejected each at `report_before_closure?`: a second-precision closure requires
`reviewed_s < closed_at`. No report association is inserted. Acceptance remains
`unknown_acceptance`, costs/latency remain null and helper coverage remains unknown.
This is the precise temporal rejection, independent of the other receipt predicates.

The regression in `elixir/test/symphony_elixir/report_delivery_test.exs` builds the
three published timing shapes with synthetic source, scope, worker and receipt identities.
It shifts observation and closure times by the same offset to stay within native
history retention. The real GitHub observer returns each candidate, while the real
Orchestrator/Operations inventory rejects retention across replay and restart.
Original attempt budgets are preserved and receipt polling imports no usage.

## Producer investigation

The legacy producer at
[`4f601c92b6edc43e75168bf7c8422fd976f12452`](https://github.com/ahammer/metalrain/tree/4f601c92b6edc43e75168bf7c8422fd976f12452)
sets a fresh local `time.time()` during terminal-log accounting in `retain_usage`.
`independent_review` retains that accounting before copying approved review output;
validation and closure follow. Terminal rows have type/usage without a source-bound
completion time. Review timing retains monotonic elapsed duration alone.

A fresh authenticated GitHub Date header was approximately 146 seconds behind the
producer machine's local clock on October 10. This supports clock/source mismatch as
an explanation, but does not prove the historical offset or actual approval time.
The old receipts cannot distinguish all delayed-accounting, clock-mismatch and late-review
histories. Mtime, duration and today's offset cannot reconstruct approval. A workpad's
creation time also cannot date review: the producer can append annotations by editing an
older comment and append further verification attempts later.

## Delivered completion contract

[MetalRain #1258](https://github.com/ahammer/metalrain/issues/1258) delivered the producer
prerequisite through normal publication in [PR #1259](https://github.com/ahammer/metalrain/pull/1259)
and [#1260](https://github.com/ahammer/metalrain/issues/1260), on main
`e833924acfe70fe741ea89c9864f4a0507fdca98`. The supported v1
[schema](https://github.com/ahammer/metalrain/blob/e833924acfe70fe741ea89c9864f4a0507fdca98/docs/development/symphony.md#review-completion-and-closure-ordering),
[producer](https://github.com/ahammer/metalrain/blob/e833924acfe70fe741ea89c9864f4a0507fdca98/tools/symphony-review-completion.py)
and [scrubbed fixture](https://github.com/ahammer/metalrain/blob/e833924acfe70fe741ea89c9864f4a0507fdca98/tools/symphony-review-completion-fixture.json)
establish the event before consumer validation changes. The synthetic fixture establishes
schema compatibility; it does not prove a real closure.

`review-completion.json` commits approved review and validation/input bytes, exact
repository/issue/source/base/scope, original receipt/delivery attempt, reviewer run/thread
and parent worker/attempt. The event identity hashes recursively sorted, compact UTF-8 JSON
excluding its own ID. Integer completion values are required. Original usage identity is
committed separately, excluding accounting observations, tokens and debits.

Native producer wall-clock start/completion/accepted times attribute the entire review
window to exactly one retained original worker. They have `ordering_authority=false`.
GitHub ordering comes from a new, immutable, digest-only comment committing the event.
The observer freshly authenticates its exact ID, issue, body and unchanged creation/update
fields and rejects duplicate anchors. `closure-ordering.json` and captured input must agree
on the pre-review closed/reopened lifecycle. Fresh authenticated lifecycle must equal that
prefix plus exactly one completed closure matching current state/reason/`closed_at`.
The anchor must occupy an earlier GitHub second than closure, and the prior lifecycle must
precede the anchor. Fractional v1 times, same-second equality, missing identity/time,
changed prefixes, late anchors and reopen/reclose do not supply ordering proof.

Delayed accounting cannot change completion or establish earlier approval. Legacy receipts
and retained observation-only proof remain unknown without supported completion evidence;
none of the three historical approvals is backdated. Only a committed and freshly
authenticated anchor demonstrably before a reopen excludes an old reference. A new closure
needs its own exact completion and prefix. Original budgets, hosted SHA, source/scope,
clean-source, unchanged-input and all failure adjudication checks remain required.

## Real canonical demonstration and validation

Using untouched private originals, authenticated GitHub GETs and a frozen native lineage
snapshot, the real Client and isolated Operations table retain MetalRain #1258 as
`repository_reported_verification`, `report_only`, with its exact original native worker/attempt
and no PR source. Its completed closure is `2026-10-11T01:20:29Z`; server ordering is proved
by its original fresh commitment anchor. Native times are checked against recorded worker
windows, never reconstructed from the event. Replay/restart preserves the association.
The real historical #1245, #1247 and #1168 receipts remain `unknown_acceptance` with
`missing-completion`.
Raw originals, review content, filesystem paths and native identifiers remain private.

Focused regressions exercise delayed/missing usage observation, genuinely late anchors,
missing completion/native/GitHub time, same-second/fractional ambiguity, edited/foreign/
duplicate anchors, reopening before first publication, exact new lifecycle completion,
producer clock mismatch, copied attempts/identities, repeated reviewer IDs, replay and
restart. Accepted costs/latency and helper coverage remain unknown; receipt polling adds
no usage. Ordinary private files are bounded to 128 KiB and the committed reviewer log to
16 MiB; symlinks and oversized files supply no proof. Diagnostics publish bounded reason
codes only.

Validation commands are recorded in the single
[Crescendo workpad](https://github.com/ahammer/crescendo/issues/72#issuecomment-6103337969):
focused report tests, private authenticated real-closure audit, full leased `make all`,
deployment recovery tests and PR-description lint. Historical evidence remains historical;
producer publication does not retroactively repair the three old receipts.
