# Agile Loop Prompt Contracts

Agile Loop uses these prompt shapes for fresh child agent sessions. Both supported adapters template the same shapes: the Codex adapter (`scripts/agile-loop.sh`) sends them through `codex exec --ephemeral`, and the Claude Code adapter (`SKILL.md`) sends them through `claude -p`. Keep final JSON lines intact; adapters use them for branching and retry JSON-contract stages when the final JSON line is missing. Child sessions must reconstruct context from the repository, task file, and explicit output files rather than prior session history.

## Planning Session

Use model `gpt-5.5`.

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

Use model `gpt-5.4`.

```
You are running agile-loop stage: implement.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Drive this stage through the installed Superpowers plugin's full implementation discipline. Invoke each as a Skill (engage the installed plugin — do not merely imitate the workflow):

1. superpowers:subagent-driven-development — execute the current Superpowers plan task-by-task: a fresh implementer subagent per task, then the two-stage spec-compliance then code-quality review it prescribes, and a final whole-implementation review at the end.
2. superpowers:test-driven-development — implementer subagents write a failing test and watch it fail before any production code (RED → GREEN → REFACTOR). No production code without a failing test first.
3. superpowers:systematic-debugging — when a test fails or behavior is unexpected, root-cause it with this skill instead of guessing.
4. superpowers:verification-before-completion — before reporting DONE, run the plan's verification commands fresh and confirm the output. Evidence before claims.

Keep all changes scoped to the plan. Per-task commits on the working branch are expected.

Do not cross the ship boundary: do NOT run superpowers:finishing-a-development-branch, do NOT open a PR, and do NOT merge or push to the base branch. Review, QA, and ship are later agile-loop stages — leave the work committed on the branch and stop.

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

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

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
Maximum remediation sub-agents: {max_parallel_remediation}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

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

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

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

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

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
Maximum remediation sub-agents: {max_parallel_remediation}

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

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

Session isolation:
This is a fresh agent session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not resume any prior session.

Use /ship. Run the full ship workflow. Stop with BLOCKED if tests fail, review requires human judgment, auth is missing, or the PR cannot be created.

The final line of your response must be exactly one JSON object:
{"blocked":false,"pr_url":"https://github.com/owner/repo/pull/123","summary":"short ship summary"}
```
