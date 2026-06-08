---
name: agile-loop
description: Run the queued GStack → GSD → Superpowers → CodeRabbit → ship loop end-to-end. Reads tasks from `docs/agile-loop/tasks/*.md`, spawns isolated child sessions per stage, opens one PR per task, and waits for the human to merge before continuing. Use when asked to "run the agile loop", "process the next queued task", or "drive the autonomous engineering loop".
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
argument-hint: "[--repo PATH] [--base BRANCH] [--max-iterations N] [--poll-interval SECONDS] [--unsafe-bypass-approvals] [--dry-run]"
---

# Agile Loop — Claude Code adapter

You are the Claude Code adapter for Agile Loop. The Codex adapter lives at `scripts/agile-loop.sh` and runs the same contract via `codex exec --ephemeral`; you run it via `claude -p` headless child sessions. Both adapters read the same `docs/agile-loop/tasks/*.md` queue and write the same `.agile-loop/status.json` (the dashboard at `scripts/agile-dashboard.py` works on either path). `references/prompts.md` is shared documentation of the host-neutral prompt shapes; the templates Claude actually sends are inlined in **Prompt templates** below so there is no runtime file lookup against the target repo.

When you spawn a child via `claude -p "<prompt>"`, that is the Claude-side equivalent of `codex exec --ephemeral`: no chat history carryover, child reconstructs all context from the repository, task file, and explicit output files.

## Pre-flight

1. Parse args (all optional): `--repo PATH` (default `$PWD`), `--base BRANCH` (default `main`), `--max-iterations N` (default 10), `--poll-interval SECONDS` (default 60), `--unsafe-bypass-approvals` (boolean), `--dry-run` (boolean). `cd` into the resolved repo root.
2. Resolve approval bypass: live runs require either `--unsafe-bypass-approvals` or `AGILE_LOOP_UNSAFE_BYPASS=1` in the environment. If neither is set and `--dry-run` is also not set, stop with a clear blocked message — the Codex adapter has the same gate (`scripts/agile-loop.sh`).
3. Confirm `git`, `gh`, `claude`, and `python3` are on `PATH`. If any are missing, write a blocked status with a clear message and stop.
4. Create `.agile-loop/` and `.agile-loop/runs/<RUN_ID>/` if missing. Generate a `RUN_ID` (UTC timestamp + short random).
5. Initialize `.agile-loop/status.json` with `status: starting` via the status writer (see **Status writer** below).
6. Print a one-line summary to the user: `Agile Loop: repo=<repo> base=<base> max=<n> dry_run=<bool> run=<RUN_ID>`.

## Child-session invocation

For every agent-backed step, spawn one fresh child via `Bash`:

```bash
claude -p "$(cat .agile-loop/runs/$RUN_ID/<stage>.prompt.md)" \
  --output-format text \
  --dangerously-skip-permissions \
  > .agile-loop/runs/$RUN_ID/<stage>.output.md \
  2> .agile-loop/runs/$RUN_ID/<stage>.events.log
```

- `--dangerously-skip-permissions` is required so the child can write files and run shell commands without prompting. Only pass it when the parent loop is gated by `--unsafe-bypass-approvals` / `AGILE_LOOP_UNSAFE_BYPASS=1`. In `--dry-run` mode, do not spawn the child at all — log "DRY RUN: would run stage=<stage>".
- The child inherits the parent's Claude model by default. If a user wants stage-specific routing, they can set `ANTHROPIC_MODEL` in the environment or add `--model <id>` to the invocation; this skill does not hard-code model identifiers (the GPT model directives in the Codex adapter's prompts are Codex-specific and intentionally omitted here).
- Build each prompt file first using the inline templates in **Prompt templates**.

## Per-iteration loop

For up to `--max-iterations` iterations, or until the queue is empty:

### 1. Pick the next task

- `Glob docs/agile-loop/tasks/*.md` sorted lexically.
- Read each file's YAML frontmatter. Pick the first with `status: todo`. If none, write `status: idle` and stop with a one-line summary.
- Edit the chosen task file's frontmatter to `status: doing`. Write status.json with `stage: claim`, `stage_status: running`, the task path in `task_file`, and the current iteration number. In `--dry-run`, do not mutate the task file; just log "would claim <task>".

### 2. Run the 11-step loop contract

The steps (identical contract to `scripts/agile-loop.sh`):

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

Update status.json before and after each step. Use `stage` values `plan`, `implement`, `coderabbit`, `remediate-coderabbit`, `gstack-review`, `qa`, `remediate-qa`, `ship`.

### Retry policy per agent-backed step

- 3 exponential-backoff retries (3s, 9s, 27s) on: child non-zero exit, empty stdout, JSON-contract stages missing the final JSON line, transient parse errors. Update status with `stage_status: retrying` between attempts.
- Do NOT retry on: explicit `BLOCKED` or `NEEDS_CONTEXT` in the child output, or `blocked: true` in a JSON-contract stage's final line. Stop immediately: write `status: blocked` with the child's reason, flip the task file frontmatter back to `status: blocked` (writing the reason into the task file body as a `## Blocked` section), and exit the loop.
- For non-JSON stages, the final `STATUS:` line drives branching. `DONE` and `DONE_WITH_CONCERNS` continue; `BLOCKED` and `NEEDS_CONTEXT` stop.

### 3. Post-merge handling

After step 10 writes `pr_url`:

1. Write `status: waiting`, `stage: poll-merge`. Every `--poll-interval` seconds, run `gh pr view <pr_url> --json state,mergedAt,mergeable`.
2. While the PR is open and unmerged, keep polling. If the PR closes unmerged, set `status: blocked` with reason "PR closed unmerged" and exit.
3. When `mergedAt` is non-null:
   - `git fetch origin <base>`.
   - `git checkout <base>`.
   - Fast-forward only: `git merge --ff-only refs/remotes/origin/<base>`. If the fast-forward fails, set `status: blocked` with reason "base branch <base> diverged from origin; cannot fast-forward" and stop. **Do not rebase or force-update.**
4. Edit the task file's frontmatter to `status: done`. Write status.json with `stage: complete`, `stage_status: completed`.
5. If iterations remain and the queue has more `todo` tasks, continue to the next iteration. Otherwise stop with `status: idle`.

## Prompt templates

Write the assembled template to `.agile-loop/runs/$RUN_ID/<stage>.prompt.md` before invoking `claude -p`. Each template ends with the same `Session isolation:` block and the exit contract (a final `STATUS:` line or a final JSON line, depending on the stage). Substitute `{repo}` with the absolute repo path, `{base}` with the base branch, `{task_file}` with the task file path, and the remediation-specific keys (`{pass}`, `{review_output}`, `{qa_output}`, `{max_parallel_remediation}` — default `3`).

The shared `Session isolation:` block (appended to every template):

```
Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.
```

### Planning Session

```
You are running agile-loop stage: plan.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Read AGENTS.md and the task file first. Use the Superpowers writing-plans skill to convert the task into a decision-complete implementation plan. Save the plan in the repo's normal Superpowers plan location unless the task file specifies a stronger location.

Stop with BLOCKED if the task lacks enough objective or acceptance context to plan safely.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

### Implementation Session

```
You are running agile-loop stage: implement.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use superpowers:subagent-driven-development to execute the current Superpowers plan task-by-task. Keep changes scoped to the plan. Run the plan's verification commands. Do not ship or create a PR.

Stop with BLOCKED if tests fail and cannot be fixed inside the task scope, if mandatory user judgment is needed, or if the plan is missing.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

### CodeRabbit Session

```
You are running agile-loop stage: coderabbit review pass {pass}.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use coderabbit:code-review. Run CodeRabbit against the current branch, passing AGENTS.md as review context when available. Do not apply fixes in this stage.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
```

### CodeRabbit Remediation Session

```
You are running agile-loop stage: remediate coderabbit.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
Review output file: {review_output}
Maximum remediation sub-agents: {max_parallel_remediation}

<<session-isolation>>

Read the CodeRabbit output. Only if it contains Critical or Major issues, spawn scoped sub-agents to fix those issues. Keep each sub-agent's write scope disjoint and tied to one finding or file group. Do not fix Minor issues unless they are necessary for a Critical or Major fix.

Run targeted validation for the changed files. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

### GStack Review Session

```
You are running agile-loop stage: gstack review.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use /review. Apply auto-fixes and handle the workflow exactly as the skill requires. Stop with BLOCKED if /review needs mandatory human judgment.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

### QA Session

```
You are running agile-loop stage: qa-only full.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use /qa-only with mode: full. This stage is report-only: do not fix. Prefer the running local app and the task/plan verification steps. Include paths to the QA report.

The final line of your response must be exactly one JSON object:
{"issues":0,"blocked":false,"report":"path or short summary"}
```

### QA Remediation Session

```
You are running agile-loop stage: remediate qa.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
QA output file: {qa_output}
Maximum remediation sub-agents: {max_parallel_remediation}

<<session-isolation>>

Read the QA report. Only if it contains issues, spawn scoped sub-agents using /investigate to root-cause and fix them. Keep each fix scoped to a reproducible QA issue.

Rerun the relevant validation for fixed issues. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

### Ship Session

```
You are running agile-loop stage: ship.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use /ship. Run the full ship workflow. Stop with BLOCKED if tests fail, review requires human judgment, auth is missing, or the PR cannot be created.

The final line of your response must be exactly one JSON object:
{"blocked":false,"pr_url":"https://github.com/owner/repo/pull/123","summary":"short ship summary"}
```

Replace `<<session-isolation>>` in every template with the shared block above.

## Status writer

Both adapters write `.agile-loop/status.json` with this schema. **These field names are canonical** — the Codex writer (`scripts/agile-loop.sh::write_status`) and the dashboard (`scripts/agile-dashboard.py`) read these exact keys, so the Claude adapter must use them verbatim. Earlier wording that referred to `loop_status` or `task` was wrong; use `status` and `task_file`.

```json
{
  "run_id": "<RUN_ID>",
  "repo": "<absolute repo path>",
  "base": "<base branch>",
  "status": "starting|running|waiting|blocked|idle|dry_run",
  "stage": "claim|plan|implement|coderabbit|remediate-coderabbit|gstack-review|qa|remediate-qa|ship|poll-merge|sync-base|complete|dashboard",
  "stage_status": "running|completed|failed|retrying|blocked|waiting|skipped",
  "message": "human-readable summary",
  "task_file": "<absolute path to task file, or empty>",
  "task_title": "<title from task frontmatter, or task file stem>",
  "iteration": 1,
  "pr_url": "https://github.com/owner/repo/pull/123",
  "dry_run": false,
  "run_dir": "<absolute path to .agile-loop/runs/$RUN_ID>",
  "log_file": "<absolute path to loop log>",
  "updated_at": "2026-06-08T17:00:00Z"
}
```

Write status atomically — temp file under `.agile-loop/` then `mv`. The canonical implementation is `write_status()` in `scripts/agile-loop.sh`; mirror its field names and behavior exactly. A small `python3 -c` heredoc invoked via `Bash` is sufficient — pass each value as an argv arg and let Python build the dict.

## Guardrails (non-negotiable)

- One PR per queued task.
- Stop instead of guessing on: `BLOCKED`, `NEEDS_CONTEXT`, failed tests, mandatory user judgment, missing authentication, or closed-unmerged PR state.
- Delegate CodeRabbit and QA fixes only after findings exist (no preemptive cleanup).
- Keep remediation scoped to the finding source. Do not broaden into cleanup.
- Prefer repo guidance from `AGENTS.md` when present in the target repo.
- Do not skip the human merge gate. The loop continues only after the PR is merged.
- Do not mark a task `done` until the configured base branch has successfully fast-forwarded to `origin/<base>`. Do not use a post-merge rebase to replay local base-branch commits.
- `--dry-run` prints what would happen and writes `status: dry_run` / `stage_status: skipped` for each stage. Do not spawn child sessions, do not mutate task files, do not run `git fetch` or `gh` write operations.
- Live runs must be opted into with `--unsafe-bypass-approvals` (or `AGILE_LOOP_UNSAFE_BYPASS=1`); otherwise refuse to spawn child sessions.

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

- Prompt contracts (host-neutral documentation): `references/prompts.md`. Both adapters inline equivalent templates at runtime; that file is the spec, not a runtime dependency.
- Codex adapter (reference implementation for retry / JSON parsing / status writes): `scripts/agile-loop.sh`.
- Dashboard: `scripts/agile-dashboard.py` (defaults to `http://127.0.0.1:8765`; reads `.agile-loop/status.json`).
- Codex-side metadata: `agents/openai.yaml`. Claude-side metadata: `agents/claude.yaml`.
