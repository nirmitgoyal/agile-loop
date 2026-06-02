# Agile Loop

Agile Loop runs a queued engineering loop for agent-assisted repos:
GStack spec -> GSD phase -> Superpowers plan -> implementation -> review/QA ->
ship -> human merge.

The maintained runner is Codex-specific and launches fresh child sessions with
`codex exec --ephemeral`. The installer can copy the skill into Codex, Claude
Code, or Antigravity, but non-Codex hosts need their own runner adapter.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash
```

Useful flags: `--host codex|claude|antigravity|all`, `--scope user|project`,
`--upgrade`, `--dry-run`.

## Requirements

- Codex CLI on `PATH` as `codex`.
- Python 3 for the dashboard.
- `git` and GitHub CLI `gh`.
- GStack, GSD, Superpowers, and CodeRabbit skills available in the target repo.

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

## Run

Start with a dry run:

```bash
~/.codex/skills/agile-loop/scripts/agile-loop.sh \
  --repo /path/to/your/repo \
  --base main \
  --max-iterations 1 \
  --dry-run
```

Run the loop:

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

Start the dashboard:

```bash
~/.codex/skills/agile-loop/scripts/agile-dashboard.py \
  --repo /path/to/your/repo \
  --port 8765
```

It serves `http://127.0.0.1:8765` and reads `.agile-loop/status.json`.