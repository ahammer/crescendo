# Crescendo maintenance guidelines

Crescendo is an Elixir/Phoenix service that runs unattended coding agents across several
repositories. These rules apply to every agent working in this repository.

## Gate

- `cd elixir && mise exec -- make all` must pass before any pull request: format check, credo
  (120-column lines, low complexity), `@spec` on every public function, 100% test coverage for
  non-ignored modules, and dialyzer.
- Prefer narrow tests that exercise real OTP processes over mocks; prove health with a synchronous
  call or an observable effect.

## Boundaries

- This repository runs you. Never touch the running service: no `systemctl` on `crescendo*` units,
  no edits under `~/.config/crescendo`, `~/.local/state/crescendo` or `~/.local/lib/crescendo`, and
  never run `ops/bin/deploy`. Reading them (and `$CRESCENDO_STATE_URL`) to understand the service
  is fine. Changes reach the service only through merged pull requests, which the deploy timer
  ships.
- The web dashboard is public and must stay strictly read-only: no endpoint or control that changes
  configuration or dispatches work. Configuration lives in local files.
- Nothing is ever parked waiting for a person: blocked work is retried and, after its attempts,
  delivered in reduced scope or closed with a reason.

## Conventions

- Keep the implementation aligned with `SPEC.md`; a behaviour change updates `SPEC.md`,
  `elixir/README.md` and `docs/crescendo.md` in the same pull request.
- Simplicity first: the smallest coherent design with one owner per piece of state. No speculative
  options or duplicated policy.
- Follow `elixir/AGENTS.md` and `elixir/docs/logging.md`.

## Native delivery prerequisites

- Before ending the turn on an unchanged, actually required existing producer, retain preparation,
  source/evidence and unmet gates on the canonical owner, then attach/read back its native GitHub
  dependency within existing task authority. Resolve explicit repository/issue identity to the global
  numeric `id`; read all blocker pages, POST `{"issue_id": ID}` only if absent, and verify `id`,
  `repository_url` and `number` afterward. After timeout or duplicate, read back before retrying.
- With a verified open native producer, keep the consumer open and its PR draft, then end the turn
  without a blocked label, including on the final attempt. Ordinary blocked/final-attempt disposition
  rules apply only when there is no verified open native prerequisite.
- Optional work and arbitrary mentions grant no edge or authority to start another project. Leave ready
  and native ownership intact; use current admission/reconciliation and the original budget, without
  holds, replacement clones or weaker acceptance. Uncertain reads use bounded recovery; `not_planned`
  or another repository's same-number completion cannot satisfy the prerequisite. See the operator-only
  [local prompt rollout](../../docs/crescendo.md#registering-real-native-prerequisites); never edit the running installation.
