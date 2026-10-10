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

`GitHub.Client.read_report` currently assigns `review-usage.json.observed_at_epoch`
to `reviewed_s`. With a matching worker window, `Operations.retain_report_verification`
then rejects each at `report_before_closure?`: a second-precision closure requires
`reviewed_s < closed_at`. No report association is inserted. Acceptance remains
`unknown_acceptance`, costs/latency remain null and helper coverage remains unknown.
This is the precise temporal rejection, independent of the other receipt predicates.

The regression in `elixir/test/symphony_elixir/report_delivery_test.exs` builds the
three published timing shapes with synthetic source, scope, worker and receipt identities.
It shifts observation and closure times by the same offset to stay within native
history retention. The real GitHub observer returns each candidate, while the real
Orchestrator/Operations inventory rejects retention across replay and restart.
Original attempt budgets are preserved and receipt polling imports no usage.

## Producer evidence and limits

Producer source inspected at MetalRain main
[`4f601c92b6edc43e75168bf7c8422fd976f12452`](https://github.com/ahammer/metalrain/tree/4f601c92b6edc43e75168bf7c8422fd976f12452):

- `tools/symphony-codex.py:retain_usage` scans CLI terminal rows and sets
  `observed_at_epoch = time.time()` at accounting observation. It creates a usage run ID
  there, rather than retaining a source-bound completion event ID.
- `tools/symphony-deliver.py:independent_review` calls that accounting producer before
  copying the approved review output. `verify_existing` then validates the review,
  source, input digest and hosted checks, retains closure intent, and invokes
  `finish_existing` to close through GitHub.
- Retained terminal CLI rows have type and usage, without a completion timestamp.
  `logged` retains monotonic elapsed duration in `review.timing.json`, without a
  corresponding absolute start or completion time.

A fresh authenticated GitHub response Date header was approximately 146 seconds behind
this machine's local wall clock on 2026-10-10. This supports clock/source mismatch as
an explanation for the ordering anomaly. It does not prove the historical clock offset,
actual approval time, or that every historical execution followed the inspected source.
The available receipts cannot distinguish all delayed-accounting, clock-mismatch and
late-review histories. File modification times, elapsed durations and today's clock
offset cannot establish earlier approval.

## Delivery prerequisite

[MetalRain #1258](https://github.com/ahammer/metalrain/issues/1258) coordinates the
missing completion event through normal producer grooming and delivery. It must retain
immutable issue/source/scope/review and worker/run/attempt identity before closure,
with ordering that is trustworthy against GitHub's clock. Native worker-window attribution
and GitHub lifecycle ordering need distinct clock provenance. A new local wall-clock
field alone does not solve this mismatch.

Consumer validation must wait for a supported producer contract and real canonical
closure demonstration. Existing ambiguous receipts remain unknown unless original
applicability and ordering can actually be proved. Keep the temporal checks, exact
source/scope and hosted SHAs, unique worker attribution, budgets and all adjudication
checks. Delayed accounting must not change completion identity; post-closure approval,
missing timing, same-second ambiguity, reopen/reclose, clock mismatch, replay and restart
must be tested against the delivered contract. No receipt backdating or fabricated PR
is justified. Raw receipts, private identifiers and filesystem paths remain private;
public diagnostics should contain only bounded rejection reasons.
