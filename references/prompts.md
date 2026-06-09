# Agile Loop Prompt Contracts

Agile Loop uses these prompt shapes for fresh child agent sessions. Both supported adapters template the same shapes: the Codex adapter (`scripts/agile-loop.sh`) sends them through `codex exec --ephemeral`, and the Claude Code adapter (`SKILL.md`) sends them through `claude -p`. Keep final JSON lines intact; adapters use them for branching and retry JSON-contract stages when the final JSON line is missing. Child sessions must reconstruct context from the repository, task file, and explicit output files rather than prior session history.

## Planning Session

Plan tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: plan.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Read AGENTS.md and the task file first. Use the Superpowers writing-plans skill to convert the task into a decision-complete implementation plan. Save the plan in the repo's normal Superpowers plan location unless the task file specifies a stronger location.

Stop with BLOCKED if the task lacks enough objective or acceptance context to plan safely.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## Implementation Session

Implementation tier — Codex: `gpt-5.4`, Claude: `claude-opus-4-7`.

```
You are running agile-loop stage: implement.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Use superpowers:subagent-driven-development to execute the current Superpowers plan task-by-task. Keep changes scoped to the plan. Run the plan's verification commands. Do not ship or create a PR.

Stop with BLOCKED if tests fail and cannot be fixed inside the task scope, if mandatory user judgment is needed, or if the plan is missing.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## Deep Review Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

Each host runs the review with its strongest code-review capability: the Claude Code adapter uses the built-in `/code-review` at high effort; the Codex adapter performs an equivalent rigorous senior-level review. The prompt body below stays host-neutral.

```
You are running agile-loop stage: deep review pass {pass}.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Perform a rigorous code review of the current branch's diff against {base}, covering correctness, security, edge cases, error handling, and simplification/efficiency. Pass AGENTS.md as additional context when present. This stage is report-only: do not apply fixes.

Classify each finding by severity:
- critical: correctness/security defects unsafe to merge or that break the feature.
- major: likely bugs, missing error handling, or significant design problems.
- minor: style, naming, small cleanups, or non-blocking suggestions.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
```

## Deep Review Remediation Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: remediate deep review.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
Review output file: {review_output}
Maximum remediation sub-agents: {max_parallel_remediation}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Read the deep-review output. Only if it contains Critical or Major issues, spawn scoped sub-agents to fix those issues. Keep each sub-agent's write scope disjoint and tied to one finding or file group. Do not fix Minor issues unless they are necessary for a Critical or Major fix.

Run targeted validation for the changed files. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## GStack Review Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: gstack review.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Use /review. Apply auto-fixes and handle the workflow exactly as the skill requires. Stop with BLOCKED if /review needs mandatory human judgment.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## QA Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: qa-only full.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Use /qa-only with mode: full. This stage is report-only: do not fix. Prefer the running local app and the task/plan verification steps. Include paths to the QA report.

The final line of your response must be exactly one JSON object:
{"issues":0,"blocked":false,"report":"path or short summary"}
```

## QA Remediation Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: remediate qa.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
QA output file: {qa_output}
Maximum remediation sub-agents: {max_parallel_remediation}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Read the QA report. Only if it contains issues, spawn scoped sub-agents using /investigate to root-cause and fix them. Keep each fix scoped to a reproducible QA issue.

Rerun the relevant validation for fixed issues. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## Ship Session

Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`.

```
You are running agile-loop stage: ship.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Use /ship. Run the full ship workflow. Stop with BLOCKED if tests fail, review requires human judgment, auth is missing, or the PR cannot be created.

The final line of your response must be exactly one JSON object:
{"blocked":false,"pr_url":"https://github.com/owner/repo/pull/123","summary":"short ship summary"}
```
