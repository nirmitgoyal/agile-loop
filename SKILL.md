---
name: agile-loop
description: Run the queued GStack → GSD → Superpowers → CodeRabbit → ship loop end-to-end. Reads tasks from `docs/agile-loop/tasks/*.md`, spawns isolated child sessions per stage, opens one PR per task, and waits for the human to merge before continuing. Use when asked to "run the agile loop", "process the next queued task", or "drive the autonomous engineering loop".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
argument-hint: "[--repo PATH] [--base BRANCH] [--max-iterations N] [--poll-interval SECONDS] [--dry-run]"
---

# Agile Loop — Claude Code adapter

You are the Claude Code adapter for Agile Loop. The Codex adapter lives at `scripts/agile-loop.sh` and runs the same contract via `codex exec --ephemeral`; you run it via `claude -p` headless child sessions. Both adapters share the queue, prompt shapes (`references/prompts.md`), `.agile-loop/status.json` schema, and dashboard.

When you spawn a child session via `claude -p "<prompt>"`, that is the Claude-side equivalent of `codex exec --ephemeral`: no chat history carryover, child reconstructs all context from the repository, task file, and explicit output files.

## Pre-flight

1. Parse args (all optional): `--repo PATH` (default `$PWD`), `--base BRANCH` (default `main`), `--max-iterations N` (default 10), `--poll-interval SECONDS` (default 60), `--dry-run` (default false). `cd` into the resolved repo root.
2. Confirm `git`, `gh`, `claude`, and `python3` are on `PATH`. If any are missing, write a blocked status with a clear message and stop.
3. Create `.agile-loop/` and `.agile-loop/runs/<run-id>/` if missing. Generate a `RUN_ID` (e.g. UTC timestamp + short random).
4. Initialize `.agile-loop/status.json` with `loop_status: starting` (use the status writer below).
5. Print a one-line summary to the user: `Agile Loop: repo=<repo> base=<base> max=<n> dry_run=<bool> run=<RUN_ID>`.

## Per-iteration loop

For up to `--max-iterations` iterations, or until the queue is empty:

### 1. Pick the next task

- `Glob docs/agile-loop/tasks/*.md` sorted lexically.
- Read each file's YAML frontmatter. Pick the first with `status: todo`. If none, write `loop_status: idle` and stop cleanly with a one-line summary.
- Edit the chosen task file's frontmatter to `status: doing`. Write status.json with `stage: claim`, `stage_status: running`, the task path, and the current iteration number. In `--dry-run`, do not mutate the task file; just log "would claim <task>".

### 2. Run the 11-step loop contract

For every agent-backed step, spawn a fresh child session via `Bash`:

```bash
claude -p "$(cat .agile-loop/runs/$RUN_ID/<stage>.prompt.md)" --output-format text \
  > .agile-loop/runs/$RUN_ID/<stage>.output.md \
  2> .agile-loop/runs/$RUN_ID/<stage>.events.log
```

Write each prompt to its own file first (using the templates in the **Prompt templates** section below), then invoke `claude -p` against that file. Update status.json before and after each step.

The steps (mirrors `references/prompts.md` and `scripts/agile-loop.sh`):

1. **Plan** — `Planning Session` template. Convert the task into a Superpowers plan.
2. **Implement** — `Implementation Session` template. Run `superpowers:subagent-driven-development`.
3. **CodeRabbit pass 1** — `CodeRabbit Session` template, `{pass}=1`. Parse the final JSON line `{"critical","major","minor","blocked","summary"}`.
4. **Remediate CodeRabbit** — `CodeRabbit Remediation Session` template. Only spawn if pass 1 has `critical>0 || major>0`. Pass the pass-1 output file path as `{review_output}`.
5. **GStack review** — `GStack Review Session` template. Runs `/review`.
6. **QA** — `QA Session` template. Parse final JSON line `{"issues","blocked","report"}`.
7. **Remediate QA** — `QA Remediation Session` template. Only if `issues>0`. Pass the QA output path as `{qa_output}`.
8. **CodeRabbit pass 2** — `CodeRabbit Session` template, `{pass}=2`. Parse the same JSON shape.
9. **Remediate CodeRabbit pass 2** — only if pass 2 has `critical>0 || major>0`.
10. **Ship** — `Ship Session` template. Parse the final JSON line `{"blocked","pr_url","summary"}`. Capture `pr_url`.
11. **Poll for merge** — see **Post-merge handling** below.

### Retry policy per agent-backed step

- 3 exponential-backoff retries (3s, 9s, 27s) on: child non-zero exit, empty stdout, JSON-contract stages missing the final JSON line, transient parse errors. Update status with `stage_status: retrying` between attempts.
- Do NOT retry on: explicit `BLOCKED` or `NEEDS_CONTEXT` in the child output, or `blocked: true` in a JSON-contract stage's final line. Stop immediately: write `loop_status: blocked` with the child's reason, flip the task file frontmatter back to `status: blocked` (writing the reason into the task file body as a `## Blocked` section), and exit the loop.
- For non-JSON stages, the final `STATUS:` line drives branching. `DONE` and `DONE_WITH_CONCERNS` continue; `BLOCKED` and `NEEDS_CONTEXT` stop.

### 3. Post-merge handling

After step 10 writes `pr_url`:

1. Write `loop_status: waiting`, `stage: poll-merge`. Every `--poll-interval` seconds, run `gh pr view <pr_url> --json state,mergedAt,mergeable`.
2. While the PR is open and unmerged, keep polling. If the PR closes unmerged, set `loop_status: blocked` with reason "PR closed unmerged" and exit.
3. When `mergedAt` is non-null:
   - `git fetch origin <base>`.
   - `git checkout <base>`.
   - Fast-forward only: `git merge --ff-only refs/remotes/origin/<base>`. If the fast-forward fails, set `loop_status: blocked` with reason "base branch <base> diverged from origin; cannot fast-forward" and stop. **Do not rebase or force-update.**
4. Edit the task file's frontmatter to `status: done`. Write status.json with `stage: complete`, `stage_status: completed`.
5. If iterations remain and the queue has more `todo` tasks, continue to the next iteration. Otherwise stop with a final `loop_status: idle`.

## Prompt templates

Build the prompt body for each stage by reading the matching section in `references/prompts.md` and substituting `{repo}`, `{base}`, `{task_file}`, `{pass}`, `{review_output}`, `{qa_output}`, and `{max_parallel_remediation}` (default `3`).

You may copy each template inline at runtime rather than reading the file every step — but if you do, the wording must match `references/prompts.md` verbatim (including the `Session isolation:` block, the model directive at the top, and the JSON-contract closing line for CodeRabbit / QA / Ship). Drift between adapters silently breaks the dashboard and retry detection.

## Status writer

Both adapters write `.agile-loop/status.json` with this schema (the dashboard at `scripts/agile-dashboard.py` reads it):

```json
{
  "loop_status": "starting|running|waiting|blocked|idle|dry_run",
  "stage": "claim|plan|implement|coderabbit|remediate-coderabbit|gstack-review|qa|remediate-qa|ship|poll-merge|sync-base|complete",
  "stage_status": "running|completed|failed|retrying|blocked|waiting|skipped",
  "message": "human-readable summary",
  "task": "docs/agile-loop/tasks/<file>.md",
  "iteration": 1,
  "pr_url": "https://github.com/owner/repo/pull/123",
  "updated_at": "2026-06-08T17:00:00Z",
  "run_id": "<RUN_ID>",
  "repo": "<absolute repo path>",
  "base": "<base branch>",
  "run_dir": ".agile-loop/runs/<RUN_ID>",
  "log_file": ".agile-loop/runs/<RUN_ID>/loop.log"
}
```

Write status atomically — temp file in `.agile-loop/` then `mv`. The canonical implementation is the `write_status()` function in `scripts/agile-loop.sh`; mirror its field names exactly. A small `python3 -c` heredoc invoked via `Bash` is sufficient.

## Guardrails (non-negotiable)

- One PR per queued task.
- Stop instead of guessing on: `BLOCKED`, `NEEDS_CONTEXT`, failed tests, mandatory user judgment, missing authentication, or closed-unmerged PR state.
- Delegate CodeRabbit and QA fixes only after findings exist (no preemptive cleanup).
- Keep remediation scoped to the finding source. Do not broaden into cleanup.
- Prefer repo guidance from `AGENTS.md` when present in the target repo.
- Do not skip the human merge gate. The loop continues only after the PR is merged.
- Do not mark a task `done` until the configured base branch has successfully fast-forwarded to `origin/<base>`. Do not use a post-merge rebase to replay local base-branch commits.
- `--dry-run` prints what would happen and writes `loop_status: dry_run` / `stage_status: skipped` for each stage. Do not spawn child sessions, do not mutate task files, do not run `git fetch` or `gh` write operations.

## Queue format

Each `docs/agile-loop/tasks/*.md` file uses this shape:

```markdown
---
status: todo|doing|done|blocked
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

## References

- Prompt contracts (host-neutral): `references/prompts.md`.
- Codex adapter (reference implementation for retry / JSON parsing / status writes): `scripts/agile-loop.sh`.
- Dashboard: `scripts/agile-dashboard.py` (defaults to `http://127.0.0.1:8765`; reads `.agile-loop/status.json`).
- Codex-side metadata: `agents/openai.yaml`. Claude-side metadata: `agents/claude.yaml`.
