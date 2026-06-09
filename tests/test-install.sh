#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$SKILL_DIR/scripts/install.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "Expected file: $file" >&2
    exit 1
  fi
}

assert_not_exists() {
  local path="$1"
  if [ -e "$path" ]; then
    echo "Expected path not to exist: $path" >&2
    exit 1
  fi
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -q "$pattern" "$file" || {
    echo "Expected $file to contain $pattern" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_installed() {
  local dest="$1"
  assert_file "$dest/SKILL.md"
  assert_file "$dest/README.md"
  assert_file "$dest/scripts/agile-loop.sh"
  assert_file "$dest/scripts/agile-dashboard.py"
  assert_file "$dest/references/prompts.md"
  assert_file "$dest/docs/agile-loop-diagram.png"
  # Dev-only test scripts must never be copied into an install.
  assert_not_exists "$dest/tests"
}

run_install() {
  local name="$1"
  shift
  local home="$TMP_ROOT/$name/home"
  local project="$TMP_ROOT/$name/project"
  local codex_home="$TMP_ROOT/$name/codex-home"
  mkdir -p "$home" "$project"
  HOME="$home" \
  CODEX_HOME="$codex_home" \
  AGILE_LOOP_INSTALL_SOURCE="$SKILL_DIR" \
  "$INSTALLER" "$@" --project-dir "$project"
}

run_install codex-user --host codex > "$TMP_ROOT/codex-user.out"
assert_installed "$TMP_ROOT/codex-user/codex-home/skills/agile-loop"

if run_install codex-user-blocks --host codex > "$TMP_ROOT/codex-user-blocks-first.out"; then
  :
fi
if run_install codex-user-blocks --host codex > "$TMP_ROOT/codex-user-blocks-second.out" 2>&1; then
  echo "Expected second install to fail without --upgrade" >&2
  exit 1
fi
assert_contains "$TMP_ROOT/codex-user-blocks-second.out" "already exists"

run_install codex-user-upgrade --host codex > "$TMP_ROOT/codex-user-upgrade-first.out"
touch "$TMP_ROOT/codex-user-upgrade/codex-home/skills/agile-loop/old-marker"
run_install codex-user-upgrade --host codex --upgrade > "$TMP_ROOT/codex-user-upgrade-second.out"
assert_installed "$TMP_ROOT/codex-user-upgrade/codex-home/skills/agile-loop"
assert_not_exists "$TMP_ROOT/codex-user-upgrade/codex-home/skills/agile-loop/old-marker"

run_install self-upgrade --host codex > "$TMP_ROOT/self-upgrade-first.out"
touch "$TMP_ROOT/self-upgrade/codex-home/skills/agile-loop/self-marker"
if HOME="$TMP_ROOT/self-upgrade/home" \
  CODEX_HOME="$TMP_ROOT/self-upgrade/codex-home" \
  "$TMP_ROOT/self-upgrade/codex-home/skills/agile-loop/scripts/install.sh" \
  --host codex \
  --project-dir "$TMP_ROOT/self-upgrade/project" \
  --upgrade > "$TMP_ROOT/self-upgrade-second.out" 2>&1; then
  echo "Expected self-upgrade to fail without deleting the installed source" >&2
  exit 1
fi
assert_contains "$TMP_ROOT/self-upgrade-second.out" "source and destination are the same"
assert_installed "$TMP_ROOT/self-upgrade/codex-home/skills/agile-loop"
assert_file "$TMP_ROOT/self-upgrade/codex-home/skills/agile-loop/self-marker"

run_install claude-user --host claude > "$TMP_ROOT/claude-user.out"
assert_installed "$TMP_ROOT/claude-user/home/.claude/skills/agile-loop"

run_install antigravity-user --host antigravity > "$TMP_ROOT/antigravity-user.out"
assert_installed "$TMP_ROOT/antigravity-user/home/.gemini/antigravity/skills/agile-loop"

run_install all-user --host all > "$TMP_ROOT/all-user.out"
assert_installed "$TMP_ROOT/all-user/codex-home/skills/agile-loop"
assert_installed "$TMP_ROOT/all-user/home/.claude/skills/agile-loop"
assert_installed "$TMP_ROOT/all-user/home/.gemini/antigravity/skills/agile-loop"

run_install claude-project --host claude --scope project > "$TMP_ROOT/claude-project.out"
assert_installed "$TMP_ROOT/claude-project/project/.claude/skills/agile-loop"

run_install antigravity-project --host antigravity --scope project > "$TMP_ROOT/antigravity-project.out"
assert_installed "$TMP_ROOT/antigravity-project/project/.agents/skills/agile-loop"

run_install codex-project --host codex --scope project > "$TMP_ROOT/codex-project.out"
assert_installed "$TMP_ROOT/codex-project/project/.codex/skills/agile-loop"

run_install dry-run --host all --dry-run > "$TMP_ROOT/dry-run.out"
assert_contains "$TMP_ROOT/dry-run.out" "Would install agile-loop"
assert_not_exists "$TMP_ROOT/dry-run/codex-home"
assert_not_exists "$TMP_ROOT/dry-run/home/.claude"
assert_not_exists "$TMP_ROOT/dry-run/home/.gemini"

home_auto="$TMP_ROOT/auto/home"
project_auto="$TMP_ROOT/auto/project"
mkdir -p "$home_auto/.claude" "$project_auto"
HOME="$home_auto" \
CODEX_HOME="$TMP_ROOT/auto/codex-home" \
AGILE_LOOP_INSTALL_SOURCE="$SKILL_DIR" \
PATH="/usr/bin:/bin" \
"$INSTALLER" --project-dir "$project_auto" > "$TMP_ROOT/auto.out"
assert_installed "$home_auto/.claude/skills/agile-loop"
assert_not_exists "$TMP_ROOT/auto/codex-home"
assert_not_exists "$home_auto/.gemini"

echo "agile-loop installer tests passed"
