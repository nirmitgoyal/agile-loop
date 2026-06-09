# Replace CodeRabbit with a high-end model "deep-review" stage

**Date:** 2026-06-09
**Status:** Approved (design) — pending spec review before planning

## Problem

The Agile Loop runs its code-review gate through the third-party `coderabbit:code-review`
skill, in two passes (pass 1 before QA, pass 2 after), each followed by conditional
remediation when `critical + major > 0`. We want to replace CodeRabbit with a rigorous
review performed **directly by the top-tier model**, so the review tier is always one
notch above the implementation tier (GPT 5.5 over GPT 5.4 on Codex; Opus 4.8 over Opus
4.7 on Claude).

This is a faithful swap of the *review mechanism*, *stage names*, and *Claude-side model
routing only*. The two-pass structure, the `critical + major > 0` remediation gate, the
separate gstack `/review` stage, QA, ship, and the merge/poll/sync flow are all unchanged.

## Current state (for reference)

- **Stages** (both adapters): plan → implement → coderabbit pass 1 → [remediate] →
  gstack `/review` → qa → [remediate] → coderabbit pass 2 → [remediate] → ship →
  poll-merge → sync-base.
- **CodeRabbit wiring** lives in 5 files: `SKILL.md`, `scripts/agile-loop.sh`,
  `references/prompts.md`, `README.md`, `tests/test-agile-loop.sh`. The dashboard
  (`scripts/agile-dashboard.py`) renders stage names dynamically and needs no change.
- **Codex models** already tier review above implementation:
  `REVIEW_MODEL=gpt-5.5`, `IMPLEMENTATION_MODEL=gpt-5.4`, `DEFAULT_MODEL=gpt-5.5`
  (`scripts/agile-loop.sh:15-17`). **No Codex model-value changes are needed.**
- **Claude adapter** deliberately hardcodes no models ("child inherits the parent's
  Claude model"). This stance is reversed for stage-tiered Opus routing (see below).

## Locked decisions

1. **Stage naming:** rename `coderabbit` → `deep-review` and `remediate-coderabbit` →
   `remediate-deep-review` (Codex stage IDs `03/04/08/09-coderabbit-*` → `…-deep-review-*`).
2. **Review engine:** Claude adapter runs the built-in `/code-review` at `high` effort;
   Codex adapter does an equivalent senior-level rigorous review (no `/code-review` skill
   in codex). Both emit the unchanged `{critical,major,minor,blocked,summary}` JSON.
3. **Claude model routing:** add configurable Opus routing (review/plan/qa/ship default to
   `claude-opus-4-8`, implementation to `claude-opus-4-7`), via flags mirroring the Codex
   adapter. GPT identifiers remain Codex-only.

## Shared severity rubric (new)

`/code-review` does not emit critical/major/minor labels, and the remediation gate keys on
`critical + major`. Both adapters therefore instruct the reviewer to classify each finding:

- **critical** — correctness or security defects that are unsafe to merge or break the feature.
- **major** — likely bugs, missing error handling, or significant design problems that
  should be fixed before merge.
- **minor** — style, naming, small cleanups, or non-blocking suggestions.

Remediation still triggers only when `critical + major > 0` (gate unchanged).

## Model routing (Claude adapter)

New optional flags, defaults chosen to mirror the Codex tiering exactly:

| Flag | Default | Stages it drives |
|---|---|---|
| `--default-model` | `claude-opus-4-8` | plan |
| `--implementation-model` | `claude-opus-4-7` | implement |
| `--review-model` | `claude-opus-4-8` | deep-review, gstack-review, qa, all remediation, ship |

- Child invocation gains `--model <stage-model>`. If a flag is set to empty string, the
  `--model` argument is **omitted** for that stage and the child inherits the parent
  session's model.
- **Fallback note:** `--implementation-model` defaults to `claude-opus-4-7`. If that model
  ID is unavailable in an environment, a bad `--model` fails the child; the documented
  remedy is `--implementation-model ""` (inherit parent) or any valid ID.

## New prompt templates

### Deep Review Session (Claude adapter — `SKILL.md`)

```
You are running agile-loop stage: deep review pass {pass}.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Use the built-in /code-review skill at high effort to review the current branch's diff
against {base}. Pass AGENTS.md as additional review context when present. This stage is
report-only: do not apply fixes.

Classify each finding by severity:
- critical: correctness/security defects unsafe to merge or that break the feature.
- major: likely bugs, missing error handling, or significant design problems.
- minor: style, naming, small cleanups, or non-blocking suggestions.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
```

### Deep Review Session (Codex adapter — `scripts/agile-loop.sh`, free-form equivalent)

```
You are running agile-loop stage: deep review pass {pass}.

Repository: {repo}
Base branch: {base}
Task file: {task_file}

<<session-isolation>>

Perform a rigorous, senior-level code review of the current branch's diff against {base},
covering correctness, security, edge cases, error handling, and simplification/efficiency.
Use AGENTS.md as additional context when present. This stage is report-only: do not apply fixes.

Classify each finding by severity:
- critical: correctness/security defects unsafe to merge or that break the feature.
- major: likely bugs, missing error handling, or significant design problems.
- minor: style, naming, small cleanups, or non-blocking suggestions.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
```

### Deep Review Remediation Session (both adapters)

Same as today's CodeRabbit remediation template, except the heading becomes
`remediate deep review` and the body reads "Read the deep-review output." instead of
"Read the CodeRabbit output."

## Per-file change list

### `SKILL.md`
- Frontmatter `description`: `GStack → GSD → Superpowers → CodeRabbit → ship` →
  `GStack → GSD → Superpowers → review → ship`.
- Frontmatter `argument-hint`: append `[--default-model ID] [--implementation-model ID] [--review-model ID]`.
- Pre-flight: parse the three new model args with the defaults above.
- Child-session invocation block: add `--model <stage-model>` (omitted when the resolved
  model is empty). Rewrite the "child inherits the parent's Claude model … does not
  hard-code model identifiers" paragraph to describe per-stage Opus routing + the new flags,
  keeping the note that GPT identifiers are Codex-only.
- "Run the 11-step loop contract": rename steps 3, 4, 8, 9 (CodeRabbit → Deep review);
  update the stage-name list (`coderabbit`, `remediate-coderabbit` → `deep-review`,
  `remediate-deep-review`); document which model each stage uses.
- Prompt templates: rename `CodeRabbit Session` → `Deep Review Session` and
  `CodeRabbit Remediation Session` → `Deep Review Remediation Session`; swap bodies to the
  templates above.
- Status-writer schema `stage` enum: `coderabbit|remediate-coderabbit` →
  `deep-review|remediate-deep-review`.
- Guardrails: "Delegate CodeRabbit and QA fixes only after findings exist" →
  "Delegate review and QA fixes only after findings exist."

### `scripts/agile-loop.sh`
- Rename `build_coderabbit_prompt` → `build_deep_review_prompt`; replace body with the
  Codex free-form review template + rubric (drop `coderabbit:code-review`).
- Rename `build_coderabbit_remediation_prompt` → `build_deep_review_remediation_prompt`;
  "Read the CodeRabbit output." → "Read the deep-review output."
- Update call sites and stage IDs in `run_iteration`:
  `03-coderabbit-pass-1` → `03-deep-review-pass-1`,
  `04-remediate-coderabbit-pass-1` → `04-remediate-deep-review-pass-1`,
  `08-coderabbit-pass-2` → `08-deep-review-pass-2`,
  `09-remediate-coderabbit-pass-2` → `09-remediate-deep-review-pass-2`.
- Update log lines and the dry-run echo string that mention "CodeRabbit" / "coderabbit"
  → "deep review" / "deep-review".
- **Models unchanged** (review already `gpt-5.5`, implementation `gpt-5.4`).

### `references/prompts.md`
- Rename `CodeRabbit Session` / `CodeRabbit Remediation Session` sections → `Deep Review …`.
- Replace the `coderabbit:code-review` instruction with the host-neutral high-end review
  (note `/code-review` at high effort on Claude; rigorous review on Codex) + the rubric.
- Update per-session model annotations to host-neutral form, e.g.
  "Review tier — Codex: `gpt-5.5`, Claude: `claude-opus-4-8`" and
  "Implementation tier — Codex: `gpt-5.4`, Claude: `claude-opus-4-7`".
- Keep the host-neutral session-isolation wording (no "fresh Codex session" / "codex resume").

### `README.md`
- Requirements: "In the target repo: GStack, GSD, Superpowers, and CodeRabbit skills
  installed." → drop CodeRabbit; note the deep-review stage uses the built-in `/code-review`
  (no extra install). Keep GStack/GSD/Superpowers.
- (Loop summary already says "review/QA"; optionally clarify the review is a high-end-model
  `/code-review`.)

### `tests/test-agile-loop.sh`
- Fake-codex stage matchers: `"coderabbit review pass 1"` → `"deep review pass 1"`
  (stage `deep-review-pass-1`); `"remediate coderabbit"` → `"remediate deep review"`
  (stage `remediate-deep-review`); `"coderabbit review pass 2"` → `"deep review pass 2"`
  (stage `deep-review-pass-2`).
- Fake-output `case` arm: `coderabbit-pass-1|coderabbit-pass-2)` → `deep-review-pass-1|deep-review-pass-2)`.
- `run_case "coderabbit-blockers"` → `"deep-review-blockers"`.
- All `assert_session_sequence` / `assert_contains` / `assert_not_contains` references to
  `coderabbit-pass-1`, `coderabbit-pass-2`, `remediate-coderabbit` → the `deep-review` names.
- Gate behavior (which sequences include remediation) is **identical** — only names change.

### `tests/test-skill-md.sh`
- Add regression guards: SKILL.md body and `references/prompts.md` must **not** contain the
  literal `coderabbit` (case-insensitive), and SKILL.md must reference the new review
  (e.g. `/code-review` and `deep review`).
- Existing `gpt-5.x` guard stays as-is and still passes (Opus IDs don't match `gpt-5\.[0-9]+`).

## Verification / acceptance criteria

1. `bash tests/test-agile-loop.sh` passes (deep-review sequences, gate, retries, sync all green).
2. `bash tests/test-skill-md.sh` passes, including the new no-`coderabbit` guards.
3. `bash tests/test-agile-dashboard.sh` passes (unaffected; dashboard is name-agnostic).
4. `grep -ri coderabbit SKILL.md scripts/ references/ README.md` returns nothing. (The only
   remaining occurrence in the repo's runtime/contract surface is the intentional guard
   *pattern* inside `tests/test-skill-md.sh`, plus this spec doc under `docs/`.)
5. A `--dry-run` of the Codex adapter prints the deep-review stage IDs in the planned sequence.
6. SKILL.md documents the three model flags and the per-stage model map; child invocation
   shows `--model`.

## Out of scope

- No changes to the gstack `/review`, `/qa-only`, or `/ship` stages beyond model routing.
- No dashboard code changes.
- No Codex model-value changes.
- No consolidation of the deep-review and gstack `/review` stages (they coexist).
- `agents/claude.yaml` / `agents/openai.yaml` short descriptions (no CodeRabbit reference; untouched).
