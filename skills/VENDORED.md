# Vendored skills

Some skills here are vendored (copied) from an upstream project rather than
authored in this repo. They are kept **verbatim** so they can be re-diffed
against upstream on a future sync.

## Source
- **Upstream:** https://github.com/addyosmani/agent-skills
- **Commit:** 8c6530305396f341b5da7201cf1f7e390fdb863f
- **License:** MIT (Copyright (c) 2025 Addy Osmani) — full text in `LICENSE-agent-skills`.

## Vendored from upstream (verbatim)
- `planning-and-task-breakdown/`
- `code-simplification/`
- `debugging-and-error-recovery/`

These are generic, command-free behavioral guidance. They pass the same
project-level symlink mechanism as our own skills (setup-claude.sh loops over
`skills/*/`), so they need no wiring.

## Deliberately NOT vendored
- The upstream **plugin / `hooks/` layer** (auto-executing shell scripts) — the
  only real risk surface, and unneeded for our symlink-based propagation.
- The multi-tool `commands/`, `agents/` roster, and `references/` docs.
- `doubt-driven-development` — valuable but entangled with upstream-specific
  concepts (personas, `agents/`, `references/orchestration-patterns.md`,
  `/review`/`/loop`); to be adapted to a plain Claude Code subagent before adding.

## Caveats
- A few "See Also" notes in the vendored skills point at upstream files that do
  not exist here (e.g. `references/definition-of-done.md`, a `/build` command).
  These are harmless dangling notes, not errors.
- Upstream moves fast (roughly weekly releases). On any re-sync, re-diff and
  re-read before pulling changes.
