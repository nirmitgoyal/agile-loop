---
name: Agile Loop
description: Run and Monitor a GStack->GSD->Superpowers->GStack loop
---

# Agile Loop

Run a simple autonomous engineering loop for Claude Code, Codex, Anti-gravity, and similar coding agents. The loop reads queued tasks, launches fresh child sessions for each major phase, ships one PR, waits for the human to merge it, marks the task done, and moves to the next queued task.

This keeps the autonomous loop pattern, but adapts it for a GStack + GSD + Superpowers + CodeRabbit workflow. The included shell runner is a Codex CLI adapter; the queue, prompts, dashboard, and workflow contract are portable to other agent hosts.

## Quick Start

Install user-wide for detected supported hosts:

```bash
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash
```

Install for a specific host:

```bash
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash -s -- --host codex
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash -s -- --host claude
curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash -s -- --host antigravity
```

Use `--upgrade` to replace an existing install.

```bash
~/.codex/skills/agile-loop/scripts/agile-loop.sh \
  --repo /path/to/your/repo \
  --base main \
  --max-iterations 10 \
  --poll-interval 60 \
  --dry-run
```

Use `--dry-run` first to print the sessions that would run without invoking the runner adapter or changing task status.

With the included Codex adapter, real execution launches child sessions with approval and sandbox bypass. Opt in explicitly:

```bash
~/.codex/skills/agile-loop/scripts/agile-loop.sh \
  --repo /path/to/your/repo \
  --base main \
  --unsafe-bypass-approvals
```

Start the status dashboard in another terminal:

```bash
~/.codex/skills/agile-loop/scripts/agile-dashboard.py \
  --repo /path/to/your/repo
```

The dashboard serves `http://127.0.0.1:8765` by default and refreshes the runner status every 15 seconds. It uses a server-side event stream so hidden browser tabs do not fall back to one-minute timer throttling. It shows the non-done queue, current status, current stage, runner update time, last poll time, and blocked reason when blocked.

## Queue

Create one Markdown file per task under `docs/agile-loop/tasks/`.

```markdown
---
status: todo
title: Short task title
phase: optional-gsd-phase-id
---

## Objective
What to build.

## Inputs
Links to GSD phase docs, plans, screenshots, issues, or acceptance notes.

## Done
Concrete acceptance criteria.
```

Supported statuses:
- `todo`: ready for the next loop iteration.
- `doing`: claimed by the current loop.
- `done`: PR was merged by the human.
- `blocked`: child session blocked, tests failed, PR closed unmerged, or mandatory human judgment was required.

## Loop Contract

For each `todo` task, run this sequence in separate agent sessions. The included Codex runner enforces this with one fresh `codex exec --ephemeral` invocation per agent-backed step; handoff happens through repo files, task files, and stage output files, not prior child-session history.

1. Turn the GSD phase/task into a Superpowers implementation plan using `gpt-5.5`.
2. Execute the plan with `superpowers:subagent-driven-development` using `gpt-5.4`.
3. Run `coderabbit:code-review` using `gpt-5.5`.
4. Only if CodeRabbit reports Critical or Major issues, fix them with scoped sub-agents.
5. Run `/review` using `gpt-5.5`.
6. Run `/qa-only mode: full` using `gpt-5.5`.
7. Only if QA reports issues, fix them using `/investigate` and scoped sub-agents.
8. Run CodeRabbit again using `gpt-5.5`.
9. Only if Critical or Major CodeRabbit issues remain, fix them with scoped sub-agents.
10. Run `/ship` using `gpt-5.5`.
11. Poll the PR until a human merges it. Then fetch `origin/<base>`, switch to the base branch, fast-forward local `<base>` to `refs/remotes/origin/<base>`, mark the task `done`, and continue.

Every failed loop stage gets 3 exponential-backoff retries before the task is blocked. Command failures, empty child-session output, and missing final JSON lines in JSON-contract stages are retryable; explicit `BLOCKED` or `NEEDS_CONTEXT` child-session results still stop immediately.

Read `references/prompts.md` before changing the runner prompt wording. The runner expects child sessions to end with a final JSON line for CodeRabbit, QA, and ship stages.

## Guardrails

- Keep one PR per queued task.
- Stop instead of guessing when a child session reports `BLOCKED`, `NEEDS_CONTEXT`, failed tests, mandatory user judgment, missing authentication, or closed-unmerged PR state.
- Delegate CodeRabbit and QA fixes only after findings exist.
- Keep remediation scoped to the finding source. Do not broaden into cleanup.
- Prefer repo guidance from `AGENTS.md` when present.
- Do not skip the human merge gate. The loop continues only after the PR is merged.
- Do not mark a task `done` until the configured base branch has successfully fast-forwarded to `origin/<base>`. Do not use a post-merge rebase to replay local base-branch commits.

## Runner Files

- `scripts/agile-loop.sh`: the executable loop runner.
- `scripts/agile-dashboard.py`: a dependency-free web dashboard for `.agile-loop/status.json`.
- `references/prompts.md`: exact child-session prompt contracts.
- `tests/test-agile-loop.sh`: deterministic fake-command tests for runner branching and status writes.
- `tests/test-agile-dashboard.sh`: dashboard HTTP and polling smoke tests.
