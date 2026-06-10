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

# CodeRabbit has been replaced by the high-end-model deep-review stage.
if grep -qiF 'coderabbit' "$SKILL_MD"; then
  fail "SKILL.md must not reference CodeRabbit anywhere; the review stage is now deep-review"
fi
pass "SKILL.md does not reference CodeRabbit"

if grep -qiF 'coderabbit' "$PROMPTS_MD"; then
  fail "references/prompts.md must not reference CodeRabbit; the review stage is now deep-review"
fi
pass "references/prompts.md does not reference CodeRabbit"

# The deep-review stage uses the built-in /code-review skill and inlines its template.
grep -qF '/code-review' <<< "$BODY" \
  || fail "SKILL.md must reference the built-in /code-review skill for the deep-review stage"
grep -qF 'Deep Review Session' <<< "$BODY" \
  || fail "SKILL.md must inline the Deep Review Session template"
pass "SKILL.md wires the deep-review stage to /code-review"

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

# ---------------------------------------------------------------------------
# Drift guard: the three adapter surfaces (Codex runner, SKILL.md, prompts.md)
# ship the same contract three times. SKILL.md deliberately inlines its
# templates, so we cannot de-duplicate the text — instead we pin the canonical
# contract VALUES (read out of scripts/agile-loop.sh, the reference
# implementation) and assert SKILL.md and references/prompts.md agree. All
# checks are value-based greps, not line-number-based, so they survive edits
# that move text around. Any future change that makes the three files disagree
# on these values fails here.
# ---------------------------------------------------------------------------

# 1. max_parallel_remediation default. Canonical = the literal the runner
#    initializes MAX_PARALLEL_REMEDIATION to.
MAX_PARALLEL_DEFAULT="$(grep -oE '^MAX_PARALLEL_REMEDIATION="[0-9]+"' "$RUNNER_SH" | grep -oE '[0-9]+')"
[ -n "$MAX_PARALLEL_DEFAULT" ] || fail "could not read MAX_PARALLEL_REMEDIATION default out of $RUNNER_SH"
# The runner's --help must advertise the same default.
grep -qF "Defaults to $MAX_PARALLEL_DEFAULT." "$RUNNER_SH" \
  || fail "scripts/agile-loop.sh help text must advertise max-parallel default $MAX_PARALLEL_DEFAULT"
# SKILL.md documents the {max_parallel_remediation} default; it must match.
grep -qF "\`{max_parallel_remediation}\` — default \`$MAX_PARALLEL_DEFAULT\`" "$SKILL_MD" \
  || fail "SKILL.md must document {max_parallel_remediation} default \`$MAX_PARALLEL_DEFAULT\` (matches scripts/agile-loop.sh)"
# Catch a stale default left behind anywhere in SKILL.md.
if grep -oE '\{max_parallel_remediation\}` — default `[0-9]+`' "$SKILL_MD" | grep -qvF "default \`$MAX_PARALLEL_DEFAULT\`"; then
  fail "SKILL.md documents a {max_parallel_remediation} default that disagrees with scripts/agile-loop.sh ($MAX_PARALLEL_DEFAULT)"
fi
# references/prompts.md only uses the {max_parallel_remediation} placeholder and
# must not hardcode a conflicting numeric default.
if grep -oE '\{max_parallel_remediation\}[^`]*default `[0-9]+`' "$PROMPTS_MD" | grep -qvF "default \`$MAX_PARALLEL_DEFAULT\`"; then
  fail "references/prompts.md hardcodes a max_parallel_remediation default that disagrees with scripts/agile-loop.sh ($MAX_PARALLEL_DEFAULT)"
fi
pass "max_parallel_remediation default ($MAX_PARALLEL_DEFAULT) agrees across runner, SKILL.md, and prompts.md"

# 2. Retry backoff schedule. Canonical = the first delay
#    (RETRY_INITIAL_SECONDS) doubled RETRY_COUNT times, since
#    retry_delay_for_attempt() doubles from the initial each retry.
RETRY_COUNT="$(grep -oE '^RETRY_COUNT="[0-9]+"' "$RUNNER_SH" | grep -oE '[0-9]+')"
RETRY_INITIAL="$(grep -oE 'RALPH_LOOP_RETRY_INITIAL_SECONDS:-[0-9]+' "$RUNNER_SH" | grep -oE '[0-9]+$')"
[ -n "$RETRY_COUNT" ] || fail "could not read RETRY_COUNT out of $RUNNER_SH"
[ -n "$RETRY_INITIAL" ] || fail "could not read the retry initial-delay default out of $RUNNER_SH"
# Build the expected "5s, 10s, 20s"-style schedule from the runner constants.
BACKOFF_SCHEDULE=""
delay="$RETRY_INITIAL"
n=0
while [ "$n" -lt "$RETRY_COUNT" ]; do
  if [ -z "$BACKOFF_SCHEDULE" ]; then
    BACKOFF_SCHEDULE="${delay}s"
  else
    BACKOFF_SCHEDULE="$BACKOFF_SCHEDULE, ${delay}s"
  fi
  delay=$((delay * 2))
  n=$((n + 1))
done
# The runner --help must advertise the same schedule.
grep -qF "$BACKOFF_SCHEDULE" "$RUNNER_SH" \
  || fail "scripts/agile-loop.sh help text must advertise backoff schedule '$BACKOFF_SCHEDULE'"
# SKILL.md retry policy must advertise the same schedule.
grep -qF "$BACKOFF_SCHEDULE" "$SKILL_MD" \
  || fail "SKILL.md retry policy must advertise backoff schedule '$BACKOFF_SCHEDULE' (matches scripts/agile-loop.sh: $RETRY_COUNT retries doubling from ${RETRY_INITIAL}s)"
# Guard against the historical wrong schedule in either doc.
for doc in "$SKILL_MD" "$PROMPTS_MD"; do
  if grep -qE '\b3s, 9s, 27s\b' "$doc"; then
    fail "$doc still advertises the stale '3s, 9s, 27s' backoff; canonical is '$BACKOFF_SCHEDULE'"
  fi
done
pass "retry backoff schedule ($BACKOFF_SCHEDULE) agrees across runner and SKILL.md"

# 3. Stage name set. Canonical = the 'agile-loop stage: <name>' identifiers the
#    runner emits in its prompt bodies. Each must appear, verbatim, in both
#    SKILL.md and references/prompts.md so the three prompt surfaces describe the
#    same stage set.
STAGE_NAMES="$(grep -oE 'agile-loop stage: [a-z][a-z ]*[a-z]' "$RUNNER_SH" \
  | sed -E 's/^agile-loop stage: //' | sort -u)"
[ -n "$STAGE_NAMES" ] || fail "could not extract any 'agile-loop stage:' identifiers from $RUNNER_SH"
while IFS= read -r stage; do
  [ -n "$stage" ] || continue
  # Anchor on a non-letter boundary so e.g. 'ship' does not match 'shipx' and a
  # renamed/garbled identifier is caught. Stage names are [a-z ] only, so they
  # carry no regex metacharacters and are safe to embed in a pattern.
  if ! grep -qE "agile-loop stage: ${stage}([^a-z]|$)" "$SKILL_MD"; then
    fail "SKILL.md is missing the canonical stage prompt identifier 'agile-loop stage: $stage'"
  fi
  if ! grep -qE "agile-loop stage: ${stage}([^a-z]|$)" "$PROMPTS_MD"; then
    fail "references/prompts.md is missing the canonical stage prompt identifier 'agile-loop stage: $stage'"
  fi
done <<< "$STAGE_NAMES"
pass "stage name set ($(echo "$STAGE_NAMES" | paste -sd'/' -)) agrees across runner, SKILL.md, and prompts.md"

# 4. status.json status/stage enum values. The runner is the source of truth
#    for which loop-status and stage tokens get written; SKILL.md documents the
#    canonical enum in its status.json schema. Assert every core token the
#    runner actually emits is present in SKILL.md's documented enum (so the
#    dashboard's expected vocabulary cannot silently drift from the writer).
STATUS_ENUM_LINE="$(grep -F '"status": "' "$SKILL_MD" | head -n1)"
STAGE_ENUM_LINE="$(grep -F '"stage": "' "$SKILL_MD" | head -n1)"
[ -n "$STATUS_ENUM_LINE" ] || fail "SKILL.md status.json schema is missing the \"status\" enum line"
[ -n "$STAGE_ENUM_LINE" ] || fail "SKILL.md status.json schema is missing the \"stage\" enum line"

# loop_status values the runner emits (first arg to write_status).
RUNNER_STATUS_VALUES="$(grep -oE 'write_status "[a-z_]+"' "$RUNNER_SH" \
  | sed -E 's/write_status "([a-z_]+)"/\1/' | sort -u)"
[ -n "$RUNNER_STATUS_VALUES" ] || fail "could not extract loop-status values emitted by $RUNNER_SH"
# 'start', 'done', and 'completed' are runner-internal lifecycle states; the
# documented enum is the dashboard vocabulary. Assert the shared core set.
for status_value in running blocked idle dry_run; do
  grep -qF "$status_value" <<< "$RUNNER_STATUS_VALUES" \
    || fail "expected core loop-status '$status_value' to be emitted by scripts/agile-loop.sh"
  grep -qE "[\"|]$status_value[\"|]" <<< "$STATUS_ENUM_LINE" \
    || fail "SKILL.md status enum must include the canonical status '$status_value'"
done
# Core stage tokens that name pipeline phases (un-numbered) — the runner emits
# these directly and SKILL.md must document them in the stage enum.
for stage_token in claim merge sync-base complete; do
  grep -qE "[\"|]$stage_token[\"|]" <<< "$STAGE_ENUM_LINE" \
    || fail "SKILL.md stage enum must include the canonical stage '$stage_token'"
done
# The agent-backed pipeline stages (un-numbered names) must also be in the enum.
for stage_token in plan implement deep-review remediate-deep-review gstack-review qa remediate-qa ship; do
  grep -qE "[\"|]$stage_token[\"|]" <<< "$STAGE_ENUM_LINE" \
    || fail "SKILL.md stage enum must include the canonical pipeline stage '$stage_token'"
done
pass "status.json status/stage enum values agree between scripts/agile-loop.sh and SKILL.md"

echo ""
echo "OK: SKILL.md and adapter contract invariants hold."
