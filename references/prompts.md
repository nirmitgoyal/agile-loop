# Agile Loop Prompt Contracts

Agile Loop uses these prompt shapes for fresh child agent sessions. The included shell runner currently sends them through `codex exec --ephemeral`. Keep final JSON lines intact; the shell runner uses them for branching and retries JSON-contract stages when the final JSON line is missing. Child sessions must reconstruct context from the repository, task file, and explicit output files rather than prior session history.

## Planning Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: plan.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Read AGENTS.md and the task file first. Use the Superpowers writing-plans skill to convert the task into a decision-complete implementation plan. Save the plan in the repo's normal Superpowers plan location unless the task file specifies a stronger location.

Stop with BLOCKED if the task lacks enough objective or acceptance context to plan safely.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## Implementation Session

Use model `gpt-5.4`.

```
You are running agile-loop stage: implement.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Use superpowers:subagent-driven-development to execute the current Superpowers plan task-by-task. Keep changes scoped to the plan. Run the plan's verification commands. Do not ship or create a PR.

Stop with BLOCKED if tests fail and cannot be fixed inside the task scope, if mandatory user judgment is needed, or if the plan is missing.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## CodeRabbit Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: coderabbit review pass {pass}.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Use coderabbit:code-review. Run CodeRabbit against the current branch, passing AGENTS.md as review context when available. Do not apply fixes in this stage.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
```

## CodeRabbit Remediation Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: remediate coderabbit.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
Review output file: {review_output}

Read the CodeRabbit output. Only if it contains Critical or Major issues, spawn scoped sub-agents to fix those issues. Keep each sub-agent's write scope disjoint and tied to one finding or file group. Do not fix Minor issues unless they are necessary for a Critical or Major fix.

Run targeted validation for the changed files. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## GStack Review Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: gstack review.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Use /review. Apply auto-fixes and handle the workflow exactly as the skill requires. Stop with BLOCKED if /review needs mandatory human judgment.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## QA Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: qa-only full.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Use /qa-only with mode: full. This stage is report-only: do not fix. Prefer the running local app and the task/plan verification steps. Include paths to the QA report.

The final line of your response must be exactly one JSON object:
{"issues":0,"blocked":false,"report":"path or short summary"}
```

## QA Remediation Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: remediate qa.

Repository: {repo}
Base branch: {base}
Task file: {task_file}
QA output file: {qa_output}

Read the QA report. Only if it contains issues, spawn scoped sub-agents using /investigate to root-cause and fix them. Keep each fix scoped to a reproducible QA issue.

Rerun the relevant validation for fixed issues. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
```

## Ship Session

Use model `gpt-5.5`.

```
You are running agile-loop stage: ship.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Use /ship. Run the full ship workflow. Stop with BLOCKED if tests fail, review requires human judgment, auth is missing, or the PR cannot be created.

The final line of your response must be exactly one JSON object:
{"blocked":false,"pr_url":"https://github.com/owner/repo/pull/123","summary":"short ship summary"}
```
