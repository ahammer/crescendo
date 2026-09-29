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
  never run `ops/bin/deploy`.
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
