# Contributing to Crescendo

Start with the [operator guide](docs/crescendo.md) for a working local service and the
[runtime reference](elixir/README.md) for tracker and workflow behavior. Contributions should solve
one concrete problem and preserve existing local configuration. Follow [the Elixir conventions](elixir/AGENTS.md)
when changing runtime code.

## Local checks

Source development requires Git, mise, Elixir 1.19/OTP 28, and Python 3. Install dependencies with
`cd elixir && mise trust && mise install && mise exec -- mix setup`.

Run focused tests while working, then the required gate from `elixir/`:

```bash
mise exec -- make all
```

This checks formatting, lint/public function specs, tests with 100% coverage, and Dialyzer.
Changes to `ops/` should also pass `python3 -m unittest discover -s ops/tests` from the repository root.
Use isolated test configurations; tests must not launch work against your production tracker.

## Pull requests

Use the repository's PR template. Explain the concrete behavior change, compatibility and evidence
from checks. Update documentation with configuration or behavior changes. For scheduling, reload,
restart or worker-lifecycle changes, include tests of the affected lifecycle and an early adversarial
review. Keep credentials and machine-specific configuration out of examples. Preserve Apache-2.0
licensing and Symphony attribution.

Screenshots should show the actual interface and name the capture context. Distinguish observed
activity and API estimates from accepted deliveries and verified cost; do not infer performance
claims from a dashboard image.
