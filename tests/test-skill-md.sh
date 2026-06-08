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

echo ""
echo "OK: SKILL.md and adapter contract invariants hold."
