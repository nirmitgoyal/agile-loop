# Agile Loop

Agile Loop runs a queued engineering loop for agent-assisted repos:
GStack spec -> GSD phase -> Superpowers plan -> implementation -> review/QA ->
ship -> human merge.

Two adapters drive the same contract:

- **Claude Code adapter** — `SKILL.md`. Claude itself orchestrates the loop and
  spawns fresh child sessions with `claude -p` for each stage.
- **Codex adapter** — `scripts/agile-loop.sh`. A shell runner that spawns fresh
  child sessions with `codex exec --ephemeral` for each stage.

Both adapters read the same `docs/agile-loop/tasks/*.md` queue, use the
prompt shapes in `references/prompts.md`, and write the same
`.agile-loop/status.json` (the dashboard works on either path).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash
```

Useful flags: `--host claude|codex|antigravity|all`, `--scope user|project`,
`--upgrade`, `--dry-run`. The installer copies the skill into the right
location for each detected host (`~/.claude/skills/agile-loop/` for Claude
Code, `~/.codex/skills/agile-loop/` for Codex).

## Requirements

Shared:

- `git`
- GitHub CLI `gh`
- Python 3 (for the dashboard, and for status-file writes on both adapters)

Per host:

- **Claude Code path**: `claude` CLI on `PATH`.
- **Codex path**: `codex` CLI on `PATH`.

In the target repo: GStack, GSD, and Superpowers skills installed. The deep-review stage uses Claude Code's built-in `/code-review` (no extra install).

## Tasks

Create one Markdown file per task under `docs/agile-loop/tasks/`:

```markdown
---
status: todo
title: Short task title
phase: optional-gsd-phase-id
---

## Objective
What to build.

## Inputs
Links to phase docs, plans, screenshots, issues, or acceptance notes.

## Done
Concrete acceptance criteria.
```

Statuses: `todo`, `doing`, `done`, `blocked`.

## Run from Claude Code

Invoke the skill against the current repo:

```
/agile-loop --repo . --base main --max-iterations 1 --dry-run
```

Live run:

```
/agile-loop --repo . --base main --max-iterations 10 --poll-interval 60
```

Claude reads the queue, claims the next `todo` task, and drives the loop
end-to-end. Each agent-backed stage is a fresh `claude -p` child session, so
there is no chat-history carryover between stages.

## Run from Codex CLI

Start with a dry run:

```bash
~/.codex/skills/agile-loop/scripts/agile-loop.sh \
  --repo /path/to/your/repo \
  --base main \
  --max-iterations 1 \
  --dry-run
```

Live run:

```bash
~/.codex/skills/agile-loop/scripts/agile-loop.sh \
  --repo /path/to/your/repo \
  --base main \
  --max-iterations 10 \
  --poll-interval 60 \
  --unsafe-bypass-approvals
```

You can set `AGILE_LOOP_UNSAFE_BYPASS=1` instead of passing
`--unsafe-bypass-approvals`.

## Dashboard

The dashboard works for both adapters:

```bash
~/.codex/skills/agile-loop/scripts/agile-dashboard.py \
  --repo /path/to/your/repo \
  --port 8765
```

(The installer copies the same `scripts/agile-dashboard.py` into both
`~/.codex/skills/agile-loop/` and `~/.claude/skills/agile-loop/` — either copy
works.)

It serves `http://127.0.0.1:8765` and reads `.agile-loop/status.json`.

## Tests

- `tests/test-agile-loop.sh` — deterministic fake-`codex` tests for the Codex
  adapter's branching, retries, and status writes.
- `tests/test-agile-dashboard.sh` — dashboard HTTP and polling smoke tests.
- `tests/test-skill-md.sh` — frontmatter and adapter-contract validation for
  `SKILL.md`.
