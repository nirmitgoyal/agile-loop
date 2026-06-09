#!/usr/bin/env bash
set -euo pipefail

# Validates SKILL.md frontmatter and the adapter-contract invariants that keep
# the Claude Code and Codex adapters in sync.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
PROMPTS_MD="$SKILL_DIR/references/prompts.md"
RUNNER_SH="$SKILL_DIR/scripts/agile-loop.sh"
CLAUDE_YAML="$SKILL_DIR/agents/claude.yaml"
OPENAI_YAML="$SKILL_DIR/agents/openai.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

[ -f "$SKILL_MD" ] || fail "SKILL.md is missing at $SKILL_MD"
[ -f "$PROMPTS_MD" ] || fail "references/prompts.md is missing"
[ -f "$RUNNER_SH" ] || fail "scripts/agile-loop.sh is missing"
[ -f "$CLAUDE_YAML" ] || fail "agents/claude.yaml is missing (Claude Code metadata mirror)"
[ -f "$OPENAI_YAML" ] || fail "agents/openai.yaml is missing (Codex metadata mirror)"
pass "all expected files present"

# Extract the YAML frontmatter block (between the first two `---` lines).
frontmatter() {
  awk 'NR==1 && $0=="---" {flag=1; next} flag && $0=="---" {exit} flag' "$SKILL_MD"
}

FRONTMATTER="$(frontmatter)"
[ -n "$FRONTMATTER" ] || fail "SKILL.md has no YAML frontmatter"
pass "SKILL.md has frontmatter"

grep -qE '^name:[[:space:]]*agile-loop[[:space:]]*$' <<< "$FRONTMATTER" \
  || fail "SKILL.md frontmatter name must be exactly 'agile-loop' (kebab-case)"
pass "frontmatter name is 'agile-loop'"

grep -qE '^description:' <<< "$FRONTMATTER" \
  || fail "SKILL.md frontmatter is missing 'description'"
pass "frontmatter has description"

grep -qE '^allowed-tools:' <<< "$FRONTMATTER" \
  || fail "SKILL.md frontmatter is missing 'allowed-tools'"
pass "frontmatter has allowed-tools"

for tool in Bash Read Write Edit Glob; do
  grep -qE "^[[:space:]]*-[[:space:]]*$tool[[:space:]]*$" <<< "$FRONTMATTER" \
    || fail "allowed-tools is missing $tool"
done
pass "allowed-tools includes Bash, Read, Write, Edit, Glob"

grep -qE '^argument-hint:' <<< "$FRONTMATTER" \
  || fail "SKILL.md frontmatter is missing 'argument-hint'"
pass "frontmatter has argument-hint"

# Body-level invariants: SKILL.md must wire to the shared contract surfaces.
BODY="$(awk 'NR==1 && $0=="---" {flag=1; next} flag && $0=="---" {flag=2; next} flag==2' "$SKILL_MD")"

for needle in 'docs/agile-loop/tasks/' 'references/prompts.md' '.agile-loop/status.json' 'scripts/agile-dashboard.py' 'scripts/agile-loop.sh'; do
  grep -qF "$needle" <<< "$BODY" \
    || fail "SKILL.md body must reference $needle"
done
pass "SKILL.md body references queue, prompts, status file, dashboard, and Codex adapter"

# Adapter invariants — each adapter must mention its own driver.
grep -qF 'claude -p' <<< "$BODY" \
  || fail "SKILL.md (Claude adapter) must spawn child sessions via 'claude -p'"
pass "SKILL.md uses 'claude -p' for child sessions"

# Permission bypass: live runs must skip permission prompts in the child, and
# must be opted into with the same flag the Codex adapter uses.
grep -qF -- '--dangerously-skip-permissions' <<< "$BODY" \
  || fail "SKILL.md must pass --dangerously-skip-permissions so headless children can write files / run commands"
grep -qF -- '--unsafe-bypass-approvals' <<< "$BODY" \
  || fail "SKILL.md must gate live runs behind --unsafe-bypass-approvals (mirrors the Codex adapter)"
grep -qF 'AGILE_LOOP_UNSAFE_BYPASS' <<< "$BODY" \
  || fail "SKILL.md must honor AGILE_LOOP_UNSAFE_BYPASS=1 as an alternative to the flag"
pass "SKILL.md gates live runs and passes --dangerously-skip-permissions to children"

# Canonical status.json fields — match scripts/agile-loop.sh::write_status and
# scripts/agile-dashboard.py.
for key in '"status"' '"stage"' '"stage_status"' '"task_file"' '"task_title"' '"pr_url"' '"dry_run"'; do
  grep -qF "$key" <<< "$BODY" \
    || fail "SKILL.md status schema must document the canonical key $key"
done
pass "SKILL.md documents canonical status.json fields (status, task_file, etc.)"

# Non-canonical aliases that the dashboard/writer do NOT understand. Catch
# accidental regressions to the earlier wording.
if grep -qE '"loop_status"|"task"[[:space:]]*:' <<< "$BODY"; then
  fail "SKILL.md must not document 'loop_status' or '\"task\":' — the canonical keys are 'status' and 'task_file'"
fi
pass "SKILL.md does not use the non-canonical 'loop_status' / 'task' keys"

# No GPT-only model directives in the inlined prompts — those are Codex-specific
# and child claude -p sessions cannot switch to OpenAI models.
if grep -qE 'gpt-5\.[0-9]+' <<< "$BODY"; then
  fail "SKILL.md inlined prompts must not include GPT model directives (Codex-specific)"
fi
pass "SKILL.md does not embed Codex-only model directives"

# The prompts must be inlined (no relative-path lookup of prompts.md against
# the target repo at runtime).
grep -qF 'Prompt templates' <<< "$BODY" \
  || fail "SKILL.md must inline the prompt templates under a 'Prompt templates' section so there is no runtime file lookup"
grep -qE 'Planning Session|Implementation Session|Ship Session' <<< "$BODY" \
  || fail "SKILL.md must inline the per-stage prompt template headings"
pass "SKILL.md inlines the per-stage prompt templates"

grep -qE '\bcodex\b|CODEX_BIN' "$RUNNER_SH" \
  || fail "scripts/agile-loop.sh (Codex adapter) must invoke the codex CLI"
grep -qE '^[[:space:]]*--ephemeral[[:space:]]*\\?[[:space:]]*$' "$RUNNER_SH" \
  || grep -qE '\b--ephemeral\b' "$RUNNER_SH" \
  || fail "scripts/agile-loop.sh (Codex adapter) must pass --ephemeral for session isolation"
pass "scripts/agile-loop.sh invokes codex with --ephemeral"

# Both adapters must reference the shared prompts contract.
grep -qF 'references/prompts.md' "$RUNNER_SH" \
  && pass "Codex adapter references prompts.md" \
  || echo "WARN: scripts/agile-loop.sh does not mention references/prompts.md (prompts are inlined; that's the historical contract). Skipping."

# Host-neutral prompts.md: no leftover Codex-only wording.
if grep -qE 'fresh Codex session|codex resume' "$PROMPTS_MD"; then
  fail "references/prompts.md still contains Codex-specific wording; sweep to host-neutral language"
fi
pass "references/prompts.md is host-neutral"

# Both per-host metadata files exist and have an interface block.
grep -qE '^interface:' "$CLAUDE_YAML" || fail "agents/claude.yaml is missing 'interface:' block"
grep -qE '^interface:' "$OPENAI_YAML" || fail "agents/openai.yaml is missing 'interface:' block"
pass "both host metadata files have an 'interface:' block"

# Full Superpowers implementation discipline — the implement stage must drive the
# installed plugin's COMPLETE workflow (not just subagent-driven-development) and
# must stop before the ship boundary. Enforced across all three adapter surfaces
# so the "all adapters in sync" contract cannot silently regress.
SP_WORKFLOW_NEEDLES=(
  'superpowers:subagent-driven-development'
  'superpowers:test-driven-development'
  'superpowers:systematic-debugging'
  'superpowers:verification-before-completion'
  # Must appear as a prohibition in the implement prompt, not an invocation:
  'do NOT run superpowers:finishing-a-development-branch'
)
for needle in "${SP_WORKFLOW_NEEDLES[@]}"; do
  grep -qF "$needle" <<< "$BODY" \
    || fail "SKILL.md implement template must reference '$needle' (full Superpowers workflow)"
done
pass "SKILL.md implement template drives the full Superpowers workflow"

for needle in "${SP_WORKFLOW_NEEDLES[@]}"; do
  grep -qF "$needle" "$PROMPTS_MD" \
    || fail "references/prompts.md implement prompt must reference '$needle' (full Superpowers workflow)"
done
pass "references/prompts.md implement prompt drives the full Superpowers workflow"

for needle in "${SP_WORKFLOW_NEEDLES[@]}"; do
  grep -qF "$needle" "$RUNNER_SH" \
    || fail "scripts/agile-loop.sh implement prompt must reference '$needle' (full Superpowers workflow)"
done
pass "scripts/agile-loop.sh implement prompt drives the full Superpowers workflow"

echo ""
echo "OK: SKILL.md and adapter contract invariants hold."
