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
if grep -q "deep review pass 1" <<<"$prompt"; then stage="deep-review-pass-1"; fi
if grep -q "remediate deep review" <<<"$prompt"; then stage="remediate-deep-review"; fi
if grep -q "gstack review" <<<"$prompt"; then stage="gstack-review"; fi
if grep -q "qa-only full" <<<"$prompt"; then stage="qa-only"; fi
if grep -q "remediate qa" <<<"$prompt"; then stage="remediate-qa"; fi
if grep -q "deep review pass 2" <<<"$prompt"; then stage="deep-review-pass-2"; fi
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
  deep-review-pass-1|deep-review-pass-2)
    printf 'Deep review fake output\n{"critical":%s,"major":%s,"minor":0,"blocked":false,"summary":"fake"}\n' "${FAKE_CRITICAL:-0}" "${FAKE_MAJOR:-0}" > "$out"
    ;;
  qa-only)
    printf 'QA fake output\n{"issues":%s,"blocked":false,"report":"fake"}\n' "${FAKE_QA_ISSUES:-0}" > "$out"
    ;;
  ship)
    if [ "${FAKE_SHIP_NO_PR_URL:-0}" = "1" ]; then
      printf 'Ship fake output\n{"blocked":false,"summary":"fake without pr_url"}\n' > "$out"
    else
      printf 'Ship fake output\n{"blocked":false,"pr_url":"https://github.com/acme/repo/pull/1","summary":"fake"}\n' > "$out"
    fi
    ;;
  *)
    if [ -n "${FAKE_PROSE_BLOCKED_STAGE:-}" ] && [ "$stage" = "$FAKE_PROSE_BLOCKED_STAGE" ]; then
      # Prose mentions a blocked status, but the final STATUS line is DONE.
      printf 'I considered whether to emit STATUS: BLOCKED but the work is fine.\nSTATUS: DONE\n' > "$out"
    else
      printf 'STATUS: DONE\n' > "$out"
    fi
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

printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"

args=" $* "

# `gh pr view ... --json state ...`: report the PR state. Defaults to MERGED so
# a branch-cleanup-only failure looks like a successful merge to the runner.
if [[ "$args" == *" pr view "* ]] && [[ "$args" == *"state"* ]]; then
  printf '%s\n' "${FAKE_GH_PR_STATE:-MERGED}"
  exit 0
fi

if [[ "$args" == *" pr merge "* ]]; then
  # Hard merge failure: the squash merge itself fails.
  if [ "${FAKE_GH_MERGE_FAIL:-0}" = "1" ]; then
    echo "fake gh pr merge failure" >&2
    exit 9
  fi
  # Branch-delete failure: the merge succeeded but `--delete-branch` failed, so
  # `gh pr merge` exits non-zero even though `pr view` will report MERGED.
  if [ "${FAKE_GH_DELETE_BRANCH_FAIL:-0}" = "1" ]; then
    echo "fake gh pr merge branch-delete failure" >&2
    exit 9
  fi
  # Transient merge failure: fail the first N invocations, then succeed.
  if [ -n "${FAKE_GH_MERGE_FAIL_COUNT:-}" ] && [ "${FAKE_GH_MERGE_FAIL_COUNT}" != "0" ]; then
    counter_file="${FAKE_GH_MERGE_COUNTER_FILE:?}"
    current_count="0"
    if [ -f "$counter_file" ]; then
      current_count="$(cat "$counter_file")"
    fi
    if [ "$current_count" -lt "${FAKE_GH_MERGE_FAIL_COUNT}" ]; then
      echo $((current_count + 1)) > "$counter_file"
      echo "transient fake gh pr merge failure" >&2
      exit 9
    fi
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

assert_session_sequence() {
  local file="$1"
  shift
  local actual expected
  actual="$(sed 's/ exec=1 ephemeral=1 resume=0$//' "$file")"
  expected="$(printf '%s\n' "$@")"
  if [ "$actual" != "$expected" ]; then
    echo "Expected exact fresh Codex session sequence in $file" >&2
    echo "---- expected ----" >&2
    printf '%s\n' "$expected" >&2
    echo "---- actual ----" >&2
    printf '%s\n' "$actual" >&2
    exit 1
  fi
}

assert_prompts_include_session_contract() {
  local repo="$1"
  local prompt
  local found="0"
  while IFS= read -r prompt; do
    found="1"
    assert_contains "$prompt" "This is a fresh Codex session for exactly this Agile Loop stage."
    assert_contains "$prompt" "Do not rely on previous child-session chat history."
    assert_contains "$prompt" "Do not use codex resume."
  done < <(find "$repo/.agile-loop/runs" -name '*.prompt.md' -print)
  if [ "$found" != "1" ]; then
    echo "Expected prompt files under $repo/.agile-loop/runs" >&2
    exit 1
  fi
}

run_case() {
  local name="$1"
  local critical="$2"
  local major="$3"
  local qa_issues="$4"
  local merge_fail="$5"
  local expect_exit="$6"
  local fail_stage="${7:-}"
  local fail_count="${8:-0}"
  local fail_git_pull="${9:-0}"
  local pr_state="${10:-MERGED}"
  local delete_branch_fail="${11:-0}"
  local merge_fail_count="${12:-0}"

  local repo="$TMP_ROOT/$name"
  make_repo "$repo"
  write_fake_codex "$repo"
  write_fake_gh "$repo"
  write_fake_git "$repo"

  local log="$repo/codex.log"
  local git_log="$repo/git.log"
  local gh_log="$repo/gh.log"
  local rc=0
  FAKE_CODEX_LOG="$log" \
  FAKE_GIT_LOG="$git_log" \
  FAKE_GH_LOG="$gh_log" \
  FAKE_CRITICAL="$critical" \
  FAKE_MAJOR="$major" \
  FAKE_QA_ISSUES="$qa_issues" \
  FAKE_GH_MERGE_FAIL="$merge_fail" \
  FAKE_GH_PR_STATE="$pr_state" \
  FAKE_GH_DELETE_BRANCH_FAIL="$delete_branch_fail" \
  FAKE_GH_MERGE_FAIL_COUNT="$merge_fail_count" \
  FAKE_GH_MERGE_COUNTER_FILE="$repo/gh-merge-counter" \
  FAKE_FAIL_STAGE="$fail_stage" \
  FAKE_FAIL_COUNT="$fail_count" \
  FAKE_GIT_FAIL_PULL="$fail_git_pull" \
  FAKE_FAIL_COUNTER_FILE="$repo/fail-counter" \
  AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
  CODEX_BIN="$repo/bin/codex" \
  GH_BIN="$repo/bin/gh" \
  GIT_BIN="$repo/bin/git" \
  "$RUNNER" --repo "$repo" --base main --max-iterations 1 --unsafe-bypass-approvals > "$repo/run.out" 2>&1 || rc=$?

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
assert_session_sequence "$repo_zero/codex.log" \
  plan \
  implement \
  deep-review-pass-1 \
  gstack-review \
  qa-only \
  deep-review-pass-2 \
  ship
assert_prompts_include_session_contract "$repo_zero"
assert_not_contains "$repo_zero/codex.log" "remediate-deep-review"
assert_not_contains "$repo_zero/codex.log" "remediate-qa"
[ "$(status_of "$repo_zero/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_zero/.agile-loop/status.json" status completed
assert_json_value "$repo_zero/.agile-loop/status.json" stage complete
assert_json_value "$repo_zero/.agile-loop/status.json" task_title "Test task"
assert_contains "$repo_zero/gh.log" "^pr merge https://github.com/acme/repo/pull/1 --squash --admin --delete-branch$"
assert_contains "$repo_zero/git.log" "^fetch origin +refs/heads/main:refs/remotes/origin/main$"
assert_contains "$repo_zero/git.log" "^switch main$"
assert_contains "$repo_zero/git.log" "^merge --ff-only refs/remotes/origin/main$"
assert_not_contains "$repo_zero/git.log" "^pull "

repo_cr="$(run_case deep-review-blockers 1 0 0 0 0)"
assert_all_fresh_sessions "$repo_cr/codex.log"
assert_session_sequence "$repo_cr/codex.log" \
  plan \
  implement \
  deep-review-pass-1 \
  remediate-deep-review \
  gstack-review \
  qa-only \
  deep-review-pass-2 \
  remediate-deep-review \
  ship
assert_prompts_include_session_contract "$repo_cr"
assert_contains "$repo_cr/codex.log" "remediate-deep-review"
[ "$(status_of "$repo_cr/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_cr/.agile-loop/status.json" status completed

repo_qa="$(run_case qa-issues 0 0 2 0 0)"
assert_all_fresh_sessions "$repo_qa/codex.log"
assert_session_sequence "$repo_qa/codex.log" \
  plan \
  implement \
  deep-review-pass-1 \
  gstack-review \
  qa-only \
  remediate-qa \
  deep-review-pass-2 \
  ship
assert_prompts_include_session_contract "$repo_qa"
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
FAKE_GH_LOG="$repo_heartbeat/gh.log" \
FAKE_SLEEP_STAGE="plan" \
FAKE_SLEEP_SECONDS="4" \
AGILE_LOOP_STATUS_HEARTBEAT_INTERVAL="1" \
AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
CODEX_BIN="$repo_heartbeat/bin/codex" \
GH_BIN="$repo_heartbeat/bin/gh" \
GIT_BIN="$repo_heartbeat/bin/git" \
"$RUNNER" --repo "$repo_heartbeat" --base main --max-iterations 1 --unsafe-bypass-approvals > "$repo_heartbeat/run.out" 2>&1 &
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

# Auto-merge hard failure: `gh pr merge` fails AND `pr view` reports the PR is
# not MERGED, so the runner exhausts retries and blocks at the merge stage (no
# polling, no human gate). With retry, gh.log now holds several `pr merge` lines.
repo_merge_fail="$(run_case merge-fails 0 0 0 1 1 "" 0 0 OPEN)"
assert_all_fresh_sessions "$repo_merge_fail/codex.log"
[ "$(status_of "$repo_merge_fail/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_merge_fail/.agile-loop/status.json" status blocked
assert_json_value "$repo_merge_fail/.agile-loop/status.json" stage merge
assert_contains "$repo_merge_fail/gh.log" "^pr merge https://github.com/acme/repo/pull/1 --squash --admin --delete-branch$"
merge_attempts="$(grep -c '^pr merge https://github.com/acme/repo/pull/1 --squash --admin --delete-branch$' "$repo_merge_fail/gh.log")"
if [ "$merge_attempts" -lt 1 ]; then
  cat "$repo_merge_fail/run.out" >&2
  echo "Expected at least one pr merge attempt in gh.log, got $merge_attempts" >&2
  exit 1
fi

# Finding 1: the squash merge succeeds but `--delete-branch` cleanup fails, so
# `gh pr merge` exits non-zero. `pr view` reports MERGED, so the runner must
# treat it as success and the loop completes.
repo_delete_branch_fail="$(run_case delete-branch-fails-but-merged 0 0 0 0 0 "" 0 0 MERGED 1)"
assert_all_fresh_sessions "$repo_delete_branch_fail/codex.log"
[ "$(status_of "$repo_delete_branch_fail/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_delete_branch_fail/.agile-loop/status.json" status completed
assert_contains "$repo_delete_branch_fail/gh.log" "^pr merge https://github.com/acme/repo/pull/1 --squash --admin --delete-branch$"
assert_contains "$repo_delete_branch_fail/git.log" "^fetch origin +refs/heads/main:refs/remotes/origin/main$"
assert_contains "$repo_delete_branch_fail/git.log" "^switch main$"
assert_contains "$repo_delete_branch_fail/git.log" "^merge --ff-only refs/remotes/origin/main$"

# Finding 2: `gh pr merge` fails transiently the first time, then succeeds on
# retry. `pr view` reports OPEN on the failure so the runner does NOT treat it
# as an already-merged success and instead retries. The loop must complete and
# gh.log must show more than one `pr merge`.
repo_merge_retry="$(run_case transient-merge-retry 0 0 0 0 0 "" 0 0 OPEN 0 1)"
assert_all_fresh_sessions "$repo_merge_retry/codex.log"
[ "$(status_of "$repo_merge_retry/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_merge_retry/.agile-loop/status.json" status completed
merge_retry_attempts="$(grep -c '^pr merge https://github.com/acme/repo/pull/1 --squash --admin --delete-branch$' "$repo_merge_retry/gh.log")"
if [ "$merge_retry_attempts" -lt 2 ]; then
  cat "$repo_merge_retry/run.out" >&2
  echo "Expected more than one pr merge attempt after a transient failure, got $merge_retry_attempts" >&2
  exit 1
fi

repo_sync_failed="$(run_case sync-fast-forward-fails 0 0 0 0 1 "" 0 1)"
assert_all_fresh_sessions "$repo_sync_failed/codex.log"
[ "$(status_of "$repo_sync_failed/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_sync_failed/.agile-loop/status.json" status blocked
assert_json_value "$repo_sync_failed/.agile-loop/status.json" stage sync-base
assert_contains "$repo_sync_failed/git.log" "^fetch origin +refs/heads/main:refs/remotes/origin/main$"
assert_contains "$repo_sync_failed/git.log" "^switch main$"
assert_contains "$repo_sync_failed/git.log" "^merge --ff-only refs/remotes/origin/main$"
assert_not_contains "$repo_sync_failed/git.log" "^pull "

# Finding 1: dry-run must preview each DISTINCT todo task once, in queue order,
# up to --max-iterations, without mutating any task file.
add_second_task() {
  local repo="$1"
  cat > "$repo/docs/agile-loop/tasks/002-second.md" <<'EOF'
---
status: todo
title: Second task
phase: phase-test
---

## Objective
Do the second test task.
EOF
}

repo_dry_two="$TMP_ROOT/dry-run-two"
make_repo "$repo_dry_two"
add_second_task "$repo_dry_two"
write_fake_codex "$repo_dry_two"
rc=0
CODEX_BIN="$repo_dry_two/bin/codex" \
"$RUNNER" --repo "$repo_dry_two" --base main --max-iterations 2 --dry-run > "$repo_dry_two/run.out" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then
  cat "$repo_dry_two/run.out" >&2
  echo "Expected two-task dry-run to succeed" >&2
  exit 1
fi
first_count="$(grep -c "DRY RUN: next task .*001-test.md$" "$repo_dry_two/run.out")"
second_count="$(grep -c "DRY RUN: next task .*002-second.md$" "$repo_dry_two/run.out")"
if [ "$first_count" != "1" ] || [ "$second_count" != "1" ]; then
  cat "$repo_dry_two/run.out" >&2
  echo "Expected each distinct todo task previewed exactly once (got first=$first_count second=$second_count)" >&2
  exit 1
fi
[ "$(status_of "$repo_dry_two/docs/agile-loop/tasks/001-test.md")" = "todo" ]
[ "$(status_of "$repo_dry_two/docs/agile-loop/tasks/002-second.md")" = "todo" ]

repo_dry_one="$TMP_ROOT/dry-run-one"
make_repo "$repo_dry_one"
add_second_task "$repo_dry_one"
write_fake_codex "$repo_dry_one"
rc=0
CODEX_BIN="$repo_dry_one/bin/codex" \
"$RUNNER" --repo "$repo_dry_one" --base main --max-iterations 1 --dry-run > "$repo_dry_one/run.out" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then
  cat "$repo_dry_one/run.out" >&2
  echo "Expected one-iteration dry-run to succeed" >&2
  exit 1
fi
assert_contains "$repo_dry_one/run.out" "DRY RUN: next task .*001-test.md$"
assert_not_contains "$repo_dry_one/run.out" "002-second.md"
[ "$(status_of "$repo_dry_one/docs/agile-loop/tasks/001-test.md")" = "todo" ]
[ "$(status_of "$repo_dry_one/docs/agile-loop/tasks/002-second.md")" = "todo" ]

# Finding 2: prose containing "STATUS: BLOCKED" must not block when the final
# STATUS line is DONE.
repo_prose="$TMP_ROOT/prose-not-blocked"
make_repo "$repo_prose"
write_fake_codex "$repo_prose"
write_fake_gh "$repo_prose"
write_fake_git "$repo_prose"
rc=0
FAKE_CODEX_LOG="$repo_prose/codex.log" \
FAKE_GIT_LOG="$repo_prose/git.log" \
FAKE_GH_LOG="$repo_prose/gh.log" \
FAKE_PROSE_BLOCKED_STAGE="plan" \
AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
CODEX_BIN="$repo_prose/bin/codex" \
GH_BIN="$repo_prose/bin/gh" \
GIT_BIN="$repo_prose/bin/git" \
"$RUNNER" --repo "$repo_prose" --base main --max-iterations 1 --unsafe-bypass-approvals > "$repo_prose/run.out" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then
  cat "$repo_prose/run.out" >&2
  echo "Expected prose-mentioning-BLOCKED case to complete, not halt the loop" >&2
  exit 1
fi
[ "$(status_of "$repo_prose/docs/agile-loop/tasks/001-test.md")" = "done" ]
assert_json_value "$repo_prose/.agile-loop/status.json" status completed

# Finding 4: ship JSON without pr_url must block at the ship stage, before merge.
repo_no_pr="$TMP_ROOT/ship-no-pr-url"
make_repo "$repo_no_pr"
write_fake_codex "$repo_no_pr"
write_fake_gh "$repo_no_pr"
write_fake_git "$repo_no_pr"
rc=0
FAKE_CODEX_LOG="$repo_no_pr/codex.log" \
FAKE_GIT_LOG="$repo_no_pr/git.log" \
FAKE_GH_LOG="$repo_no_pr/gh.log" \
FAKE_SHIP_NO_PR_URL="1" \
AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
CODEX_BIN="$repo_no_pr/bin/codex" \
GH_BIN="$repo_no_pr/bin/gh" \
GIT_BIN="$repo_no_pr/bin/git" \
"$RUNNER" --repo "$repo_no_pr" --base main --max-iterations 1 --unsafe-bypass-approvals > "$repo_no_pr/run.out" 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  cat "$repo_no_pr/run.out" >&2
  echo "Expected ship-without-pr_url to block" >&2
  exit 1
fi
[ "$(status_of "$repo_no_pr/docs/agile-loop/tasks/001-test.md")" = "blocked" ]
assert_json_value "$repo_no_pr/.agile-loop/status.json" status blocked
assert_json_value "$repo_no_pr/.agile-loop/status.json" stage 10-ship
assert_contains "$repo_no_pr/run.out" "ship stage returned no pr_url"
if [ -f "$repo_no_pr/gh.log" ]; then
  echo "Expected no gh merge when ship returned no pr_url" >&2
  exit 1
fi

# Finding 6: a task filename containing a space must be found and processed.
repo_space="$TMP_ROOT/space-in-filename"
make_repo "$repo_space"
rm -f "$repo_space/docs/agile-loop/tasks/001-test.md"
cat > "$repo_space/docs/agile-loop/tasks/001 with space.md" <<'EOF'
---
status: todo
title: Spaced task
phase: phase-test
---

## Objective
Do the spaced test task.
EOF
write_fake_codex "$repo_space"
write_fake_gh "$repo_space"
write_fake_git "$repo_space"
rc=0
FAKE_CODEX_LOG="$repo_space/codex.log" \
FAKE_GIT_LOG="$repo_space/git.log" \
FAKE_GH_LOG="$repo_space/gh.log" \
AGILE_LOOP_RETRY_INITIAL_SECONDS="0" \
CODEX_BIN="$repo_space/bin/codex" \
GH_BIN="$repo_space/bin/gh" \
GIT_BIN="$repo_space/bin/git" \
"$RUNNER" --repo "$repo_space" --base main --max-iterations 1 --unsafe-bypass-approvals > "$repo_space/run.out" 2>&1 || rc=$?
if [ "$rc" != "0" ]; then
  cat "$repo_space/run.out" >&2
  echo "Expected task filename with a space to be found and processed" >&2
  exit 1
fi
[ "$(status_of "$repo_space/docs/agile-loop/tasks/001 with space.md")" = "done" ]
assert_json_value "$repo_space/.agile-loop/status.json" status completed
assert_all_fresh_sessions "$repo_space/codex.log"

# --- Dashboard auto-start ---

# Pick a non-default port so this test never collides with a real dashboard the
# user may be running. Use python to grab a free port and immediately release it.
dashboard_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
dashboard_repo="$TMP_ROOT/dashboard-repo"
make_repo "$dashboard_repo"

cleanup_dashboard() {
  local pids
  pids="$(lsof -ti tcp:"$dashboard_port" -sTCP:LISTEN 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids >/dev/null 2>&1 || true
  fi
}
trap 'rm -rf "$TMP_ROOT"; cleanup_dashboard' EXIT

# --dry-run avoids spawning the fake codex but exercises pre-flight (including
# ensure_dashboard).
"$RUNNER" --repo "$dashboard_repo" --dry-run --dashboard-port "$dashboard_port" \
  > "$dashboard_repo/dashboard-run.out" 2>&1

# Give the spawned dashboard a moment to bind.
for _ in 1 2 3 4 5; do
  if curl -fsS --max-time 2 "http://127.0.0.1:$dashboard_port/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

dashboard_repo_real="$(cd "$dashboard_repo" && pwd -P)"
served_repo="$(curl -fsS --max-time 2 "http://127.0.0.1:$dashboard_port/api/status" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("repo",""))')"
if [ "$served_repo" != "$dashboard_repo_real" ]; then
  cat "$dashboard_repo/dashboard-run.out" >&2
  echo "Dashboard auto-start did not bind to $dashboard_repo_real (got: $served_repo)" >&2
  exit 1
fi

# Re-run should reuse, not respawn — assert by checking the log line and that
# the listener PID does not change.
prior_pid="$(lsof -ti tcp:"$dashboard_port" -sTCP:LISTEN 2>/dev/null | head -1)"
"$RUNNER" --repo "$dashboard_repo" --dry-run --dashboard-port "$dashboard_port" \
  > "$dashboard_repo/dashboard-reuse.out" 2>&1
if ! grep -q "dashboard already serving" "$dashboard_repo/dashboard-reuse.out"; then
  cat "$dashboard_repo/dashboard-reuse.out" >&2
  echo "Expected re-run to reuse the existing dashboard" >&2
  exit 1
fi
current_pid="$(lsof -ti tcp:"$dashboard_port" -sTCP:LISTEN 2>/dev/null | head -1)"
if [ "$prior_pid" != "$current_pid" ]; then
  echo "Dashboard PID changed on re-run ($prior_pid -> $current_pid); should have been reused" >&2
  exit 1
fi

# --no-dashboard must skip the auto-start (and never bind a port).
nodash_repo="$TMP_ROOT/dashboard-skip-repo"
make_repo "$nodash_repo"
"$RUNNER" --repo "$nodash_repo" --dry-run --no-dashboard \
  > "$nodash_repo/nodash.out" 2>&1
if ! grep -q "dashboard auto-start disabled" "$nodash_repo/nodash.out"; then
  cat "$nodash_repo/nodash.out" >&2
  echo "Expected --no-dashboard to log the disabled message" >&2
  exit 1
fi

cleanup_dashboard

echo "agile-loop runner tests passed"
