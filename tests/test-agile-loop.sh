#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$SKILL_DIR/scripts/agile-loop.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

make_repo() {
  local repo="$1"
  mkdir -p "$repo/docs/agile-loop/tasks" "$repo/bin"
  cat > "$repo/AGENTS.md" <<'EOF'
# AGENTS

Test fixture.
EOF
  cat > "$repo/docs/agile-loop/tasks/001-test.md" <<'EOF'
---
status: todo
title: Test task
phase: phase-test
---

## Objective
Do the test task.

## Inputs
None.

## Done
The fake PR merges.
EOF
}

write_fake_codex() {
  local repo="$1"
  cat > "$repo/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

out=""
saw_exec="0"
saw_ephemeral="0"
saw_resume="0"
while [ "$#" -gt 0 ]; do
  case "$1" in
    exec)
      saw_exec="1"
      shift
      ;;
    resume)
      saw_resume="1"
      shift
      ;;
    --ephemeral)
      saw_ephemeral="1"
      shift
      ;;
    -o|--output-last-message)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt="$(cat)"
mkdir -p "$(dirname "$out")"
stage="unknown"
if grep -q "stage: plan" <<<"$prompt"; then stage="plan"; fi
if grep -q "stage: implement" <<<"$prompt"; then stage="implement"; fi
if grep -q "coderabbit review pass 1" <<<"$prompt"; then stage="coderabbit-pass-1"; fi
if grep -q "remediate coderabbit" <<<"$prompt"; then stage="remediate-coderabbit"; fi
if grep -q "gstack review" <<<"$prompt"; then stage="gstack-review"; fi
if grep -q "qa-only full" <<<"$prompt"; then stage="qa-only"; fi
if grep -q "remediate qa" <<<"$prompt"; then stage="remediate-qa"; fi
if grep -q "coderabbit review pass 2" <<<"$prompt"; then stage="coderabbit-pass-2"; fi
if grep -q "stage: ship" <<<"$prompt"; then stage="ship"; fi

echo "$stage exec=$saw_exec ephemeral=$saw_ephemeral resume=$saw_resume" >> "${FAKE_CODEX_LOG:?}"

if [ -n "${FAKE_FAIL_STAGE:-}" ] && [ "$stage" = "$FAKE_FAIL_STAGE" ]; then
  counter_file="${FAKE_FAIL_COUNTER_FILE:?}"
  fail_count="${FAKE_FAIL_COUNT:-0}"
  current_count="0"
  if [ -f "$counter_file" ]; then
    current_count="$(cat "$counter_file")"
  fi
  if [ "$current_count" -lt "$fail_count" ]; then
    echo $((current_count + 1)) > "$counter_file"
    echo "transient fake failure for $stage" >&2
    exit 42
  fi
fi

if [ -n "${FAKE_SLEEP_STAGE:-}" ] && [ "$stage" = "$FAKE_SLEEP_STAGE" ]; then
  sleep "${FAKE_SLEEP_SECONDS:-1}"
fi

case "$stage" in
  coderabbit-pass-1|coderabbit-pass-2)
    printf 'CodeRabbit fake output\n{"critical":%s,"major":%s,"minor":0,"blocked":false,"summary":"fake"}\n' "${FAKE_CRITICAL:-0}" "${FAKE_MAJOR:-0}" > "$out"
    ;;
  qa-only)
    printf 'QA fake output\n{"issues":%s,"blocked":false,"report":"fake"}\n' "${FAKE_QA_ISSUES:-0}" > "$out"
    ;;
  ship)
    printf 'Ship fake output\n{"blocked":false,"pr_url":"https://github.com/acme/repo/pull/1","summary":"fake"}\n' > "$out"
    ;;
  *)
    printf 'STATUS: DONE\n' > "$out"
    ;;
esac
EOF
  chmod +x "$repo/bin/codex"
}

write_fake_gh() {
  local repo="$1"
  cat > "$repo/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=" $* "
if [[ "$args" == *" --json state "* ]]; then
  if [ "${FAKE_GH_CLOSED:-0}" = "1" ]; then
    echo "CLOSED"
  else
    echo "MERGED"
  fi
  exit 0
fi

if [[ "$args" == *" --json mergedAt "* ]]; then
  if [ "${FAKE_GH_CLOSED:-0}" = "1" ]; then
    echo ""
  else
    echo "2026-05-27T00:00:00Z"
  fi
  exit 0
fi

echo ""
EOF
  chmod +x "$repo/bin/gh"
}

write_fake_git() {
  local repo="$1"
  cat > "$repo/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_GIT_LOG:?}"

case "${1:-}" in
  rev-parse)
    exit 0
    ;;
  fetch)
    exit 0
    ;;
  switch)
    exit 0
    ;;
  merge)
    if [ "${FAKE_GIT_FAIL_PULL:-0}" = "1" ]; then
      echo "fake git fast-forward failure" >&2
      exit 7
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$repo/bin/git"
}

status_of() {
  local task="$1"
  python3 - "$task" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
for line in text.splitlines():
    if line.startswith("status:"):
        print(line.split(":", 1)[1].strip())
        break
PY
}

json_value() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
value = data.get(sys.argv[2], "")
print("" if value is None else value)
PY
}

assert_json_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(json_value "$file" "$key")"
  if [ "$actual" != "$expected" ]; then
    echo "Expected $file $key to be $expected, got $actual" >&2
    exit 1
  fi
}

wait_for_json_value() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local attempts="${4:-50}"

  for _ in $(seq 1 "$attempts"); do
    if [ -f "$file" ] && [ "$(json_value "$file" "$key")" = "$expected" ]; then
      return 0
    fi
    sleep 0.1
  done

  echo "Expected $file $key to become $expected" >&2
  [ ! -f "$file" ] || cat "$file" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -q "$pattern" "$file" || {
    echo "Expected $file to contain $pattern" >&2
    echo "---- $file ----" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -q "$pattern" "$file"; then
    echo "Expected $file not to contain $pattern" >&2
    exit 1
  fi
}

assert_all_fresh_sessions() {
  local file="$1"
  if [ ! -s "$file" ]; then
    echo "Expected $file to contain Codex session invocations" >&2
    exit 1
  fi
  awk '
    $0 !~ / exec=1 ephemeral=1 resume=0$/ {
      printf("Expected fresh codex session marker in %s, got: %s\n", FILENAME, $0) > "/dev/stderr"
      exit 1
    }
  ' "$file"
}

run_case() {
  local name="$1"
  local critical="$2"
  local major="$3"
  local qa_issues="$4"
  local closed="$5"
  local expect_exit="$6"
  local fail_stage="${7:-}"
  local fail_count="${8:-0}"
  local fail_git_pull="${9:-0}"

  local repo="$TMP_ROOT/$name"
  make_repo "$repo"
  write_fake_codex "$repo"
  write_fake_gh "$repo"
  write_fake_git "$repo"

  local log="$repo/codex.log"
  local git_log="$repo/git.log"
  local rc=0
  FAKE_CODEX_LOG="$log" \
  FAKE_GIT_LOG="$git_log" \
  FAKE_CRITICAL="$critical" \
  FAKE_MAJOR="$major" \
  FAKE_QA_ISSUES="$qa_issues" \
  FAKE_GH_CLOSED="$closed" \
  FAKE_FAIL_STAGE="$fail_stage" \
  FAKE_FAIL_COUNT="$fail_count" \
  FAKE_GIT_FAIL_PULL="$fail_git_pull" \
  FAKE_FAIL_COUNTER_FILE="$repo/fail-counter" \
  AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
  CODEX_BIN="$repo/bin/codex" \
  GH_BIN="$repo/bin/gh" \
  GIT_BIN="$repo/bin/git" \
  "$RUNNER" --repo "$repo" --base main --max-iterations 1 --poll-interval 1 --poll-timeout 2 --unsafe-bypass-approvals > "$repo/run.out" 2>&1 || rc=$?

  if [ "$expect_exit" = "0" ] && [ "$rc" != "0" ]; then
    cat "$repo/run.out" >&2
    echo "Case $name failed unexpectedly" >&2
    exit 1
  fi
  if [ "$expect_exit" != "0" ] && [ "$rc" = "0" ]; then
    cat "$repo/run.out" >&2
    echo "Case $name should have failed" >&2
    exit 1
  fi
  echo "$repo"
}

repo_requires_unsafe="$TMP_ROOT/requires-unsafe"
make_repo "$repo_requires_unsafe"
write_fake_codex "$repo_requires_unsafe"
write_fake_gh "$repo_requires_unsafe"
write_fake_git "$repo_requires_unsafe"
rc=0
FAKE_CODEX_LOG="$repo_requires_unsafe/codex.log" \
FAKE_GIT_LOG="$repo_requires_unsafe/git.log" \
CODEX_BIN="$repo_requires_unsafe/bin/codex" \
GH_BIN="$repo_requires_unsafe/bin/gh" \
GIT_BIN="$repo_requires_unsafe/bin/git" \
"$RUNNER" --repo "$repo_requires_unsafe" --base main --max-iterations 1 > "$repo_requires_unsafe/run.out" 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  cat "$repo_requires_unsafe/run.out" >&2
  echo "Expected runner to require unsafe opt-in for non-dry-run execution" >&2
  exit 1
fi
assert_contains "$repo_requires_unsafe/run.out" "non-dry-run execution requires --unsafe-bypass-approvals"
[ "$(status_of "$repo_requires_unsafe/docs/agile-loop/tasks/001-test.md")" = "todo" ]
if [ -f "$repo_requires_unsafe/codex.log" ]; then
  echo "Expected unsafe gate to stop before invoking Codex" >&2
  exit 1
fi

repo_dry_run="$TMP_ROOT/dry-run"
make_repo "$repo_dry_run"
write_fake_codex "$repo_dry_run"
rc=0
FAKE_CODEX_LOG="$repo_dry_run/codex.log" \
CODEX_BIN="$repo_dry_run/bin/codex" \
"$RUNNER" --repo "$repo_dry_run" --base main --max-iterations 1 --dry-run > "$repo_dry_run/run.out" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then
  cat "$repo_dry_run/run.out" >&2
  echo "Expected dry-run to work without unsafe opt-in" >&2
  exit 1
fi
assert_contains "$repo_dry_run/run.out" "DRY RUN: next task"
[ "$(status_of "$repo_dry_run/docs/agile-loop/tasks/001-test.md")" = "todo" ]
if [ -f "$repo_dry_run/codex.log" ]; then
  echo "Expected dry-run not to invoke Codex" >&2
  exit 1
fi

repo_zero="$(run_case zero-findings 0 0 0 0 0)"
assert_all_fresh_sessions "$repo_zero/codex.log"
assert_not_contains "$repo_zero/codex.log" "remediate-coderabbit"
assert_not_contains "$repo_zero/codex.log" "remediate-qa"
[ "$(status_of "$repo_zero/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_zero/.agile-loop/status.json" status completed
assert_json_value "$repo_zero/.agile-loop/status.json" stage complete
assert_json_value "$repo_zero/.agile-loop/status.json" task_title "Test task"
assert_contains "$repo_zero/git.log" "^fetch origin +refs/heads/main:refs/remotes/origin/main$"
assert_contains "$repo_zero/git.log" "^switch main$"
assert_contains "$repo_zero/git.log" "^merge --ff-only refs/remotes/origin/main$"
assert_not_contains "$repo_zero/git.log" "^pull "

repo_cr="$(run_case coderabbit-blockers 1 0 0 0 0)"
assert_all_fresh_sessions "$repo_cr/codex.log"
assert_contains "$repo_cr/codex.log" "remediate-coderabbit"
[ "$(status_of "$repo_cr/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_cr/.agile-loop/status.json" status completed

repo_qa="$(run_case qa-issues 0 0 2 0 0)"
assert_all_fresh_sessions "$repo_qa/codex.log"
assert_contains "$repo_qa/codex.log" "remediate-qa"
[ "$(status_of "$repo_qa/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_qa/.agile-loop/status.json" status completed

repo_retry="$(run_case transient-implement-retry 0 0 0 0 0 implement 2)"
assert_all_fresh_sessions "$repo_retry/codex.log"
implement_runs="$(grep -c '^implement exec=1 ephemeral=1 resume=0$' "$repo_retry/codex.log")"
if [ "$implement_runs" != "3" ]; then
  cat "$repo_retry/run.out" >&2
  echo "Expected implement to run 3 times after two transient failures, got $implement_runs" >&2
  exit 1
fi
assert_contains "$repo_retry/run.out" "02-implement session failed with exit 42; retry 1/3"
assert_contains "$repo_retry/run.out" "02-implement session failed with exit 42; retry 2/3"
[ "$(status_of "$repo_retry/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_retry/.agile-loop/status.json" status completed

repo_heartbeat="$TMP_ROOT/status-heartbeat"
make_repo "$repo_heartbeat"
write_fake_codex "$repo_heartbeat"
write_fake_gh "$repo_heartbeat"
write_fake_git "$repo_heartbeat"
FAKE_CODEX_LOG="$repo_heartbeat/codex.log" \
FAKE_GIT_LOG="$repo_heartbeat/git.log" \
FAKE_SLEEP_STAGE="plan" \
FAKE_SLEEP_SECONDS="4" \
AGILE_LOOP_STATUS_HEARTBEAT_INTERVAL="1" \
AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
CODEX_BIN="$repo_heartbeat/bin/codex" \
GH_BIN="$repo_heartbeat/bin/gh" \
GIT_BIN="$repo_heartbeat/bin/git" \
"$RUNNER" --repo "$repo_heartbeat" --base main --max-iterations 1 --poll-interval 1 --poll-timeout 2 --unsafe-bypass-approvals > "$repo_heartbeat/run.out" 2>&1 &
heartbeat_pid="$!"

wait_for_json_value "$repo_heartbeat/.agile-loop/status.json" stage "01-plan"
heartbeat_started_at="$(json_value "$repo_heartbeat/.agile-loop/status.json" updated_at)"
sleep 2
heartbeat_mid_stage="$(json_value "$repo_heartbeat/.agile-loop/status.json" stage)"
heartbeat_mid_status="$(json_value "$repo_heartbeat/.agile-loop/status.json" stage_status)"
heartbeat_mid_updated_at="$(json_value "$repo_heartbeat/.agile-loop/status.json" updated_at)"
if [ "$heartbeat_mid_stage" != "01-plan" ] || [ "$heartbeat_mid_status" != "running" ]; then
  cat "$repo_heartbeat/run.out" >&2
  echo "Expected heartbeat case to still be running 01-plan" >&2
  exit 1
fi
if [ "$heartbeat_started_at" = "$heartbeat_mid_updated_at" ]; then
  cat "$repo_heartbeat/.agile-loop/status.json" >&2
  echo "Expected status heartbeat to refresh updated_at while child stage runs" >&2
  exit 1
fi
if ! wait "$heartbeat_pid"; then
  cat "$repo_heartbeat/run.out" >&2
  echo "Heartbeat case failed unexpectedly" >&2
  exit 1
fi
assert_json_value "$repo_heartbeat/.agile-loop/status.json" status completed

repo_retry_exhausted="$(run_case exhausted-implement-retry 0 0 0 0 1 implement 4)"
assert_all_fresh_sessions "$repo_retry_exhausted/codex.log"
implement_runs="$(grep -c '^implement exec=1 ephemeral=1 resume=0$' "$repo_retry_exhausted/codex.log")"
if [ "$implement_runs" != "4" ]; then
  cat "$repo_retry_exhausted/run.out" >&2
  echo "Expected implement to run 4 times after retry exhaustion, got $implement_runs" >&2
  exit 1
fi
assert_contains "$repo_retry_exhausted/run.out" "02-implement session failed after 4 attempts"
[ "$(status_of "$repo_retry_exhausted/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_retry_exhausted/.agile-loop/status.json" status blocked
assert_json_value "$repo_retry_exhausted/.agile-loop/status.json" stage 02-implement

repo_closed="$(run_case closed-unmerged 0 0 0 1 1)"
assert_all_fresh_sessions "$repo_closed/codex.log"
[ "$(status_of "$repo_closed/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_closed/.agile-loop/status.json" status blocked
assert_json_value "$repo_closed/.agile-loop/status.json" stage poll-merge

repo_sync_failed="$(run_case sync-fast-forward-fails 0 0 0 0 1 "" 0 1)"
assert_all_fresh_sessions "$repo_sync_failed/codex.log"
[ "$(status_of "$repo_sync_failed/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_sync_failed/.agile-loop/status.json" status blocked
assert_json_value "$repo_sync_failed/.agile-loop/status.json" stage sync-base
assert_contains "$repo_sync_failed/git.log" "^fetch origin +refs/heads/main:refs/remotes/origin/main$"
assert_contains "$repo_sync_failed/git.log" "^switch main$"
assert_contains "$repo_sync_failed/git.log" "^merge --ff-only refs/remotes/origin/main$"
assert_not_contains "$repo_sync_failed/git.log" "^pull "

echo "agile-loop runner tests passed"
