# Crescendo

Crescendo runs autonomous coding agents across several repositories from one local service. Each
project's issues and pull requests become isolated agent runs. The projects share the worker
slots, a daily budget and the Codex quota, and a read-only dashboard shows everything in one place.

Crescendo is based on [Symphony](https://github.com/openai/symphony) by OpenAI (Apache-2.0) and
implements its [specification](SPEC.md). On top of the Symphony reference implementation it adds:

- **One service for many projects.** A local `crescendo.yml` names the projects; slots are shared by
  weight (weights 3,1,1 give the first project about three times the work), with optional caps.
- **Throttling.** An enforced daily budget that keeps closing open work (pull request reviews,
  final attempts and continuations still run), and model back-off when the Codex quota runs low.
- **Model routing.** A ladder that climbs on failed attempts, size labels that start small work on a
  cheaper model, and effort floors.
- **Autopilot.** Pull requests are reviewed and merged, stuck model work is retried and then delivered in
  part or closed (nothing waits on an operator), and an empty queue is refilled by research runs per
  configurable channel. Startup failures preserve the item and dependencies for controlled recovery.
- **A read-only dashboard** across projects, with a filter per project and a
  [bounded history API](docs/crescendo.md#dashboard-and-api) for retrospectives.
- **Thread usage accounting** that survives worker restarts, with native billing coverage and
  conservative, opt-in issue-thread resumption. API estimates remain distinct from verified costs.
  See the [token-cache plan and rollout gates](elixir/docs/token_cache_optimization_plan.md).

All configuration is local: [docs/crescendo.md](docs/crescendo.md) covers the service file, and
[elixir/README.md](elixir/README.md) covers setup and the per-project `WORKFLOW.md`.

> [!WARNING]
> Crescendo is an engineering preview for trusted environments. Its agents run without the usual
> guardrails.

## Quick start

```bash
cd elixir
mise trust && mise install
mise exec -- mix setup && mise exec -- mix build
```

Create the service file and its first project using the
[first-service walkthrough](docs/crescendo.md#first-service) before launching:

```bash
CRESCENDO_DIR="${CRESCENDO_DIR:-$HOME/.config/crescendo}"
mise exec -- ./bin/crescendo "$CRESCENDO_DIR/crescendo.yml" --logs-root "$CRESCENDO_DIR/logs" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

A single `WORKFLOW.md` still runs one project on its own, as Symphony does:
`./bin/crescendo path/to/WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails`.

## About Symphony

Symphony turns project work into isolated, autonomous implementation runs, so teams manage work
instead of supervising coding agents. [`SPEC.md`](SPEC.md) is the upstream Symphony specification,
kept as published; Crescendo's extensions are documented in [docs/crescendo.md](docs/crescendo.md).

## License

This project is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for
attribution.
