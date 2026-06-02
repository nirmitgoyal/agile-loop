#!/usr/bin/env bash
set -euo pipefail

REPO=""
BASE="main"
MAX_ITERATIONS="10"
POLL_INTERVAL="60"
POLL_TIMEOUT="0"
QUEUE_GLOB="docs/agile-loop/tasks/*.md"
STATE_ROOT=".agile-loop/runs"
STATUS_FILE=".agile-loop/status.json"
STATUS_HEARTBEAT_INTERVAL="${AGILE_LOOP_STATUS_HEARTBEAT_INTERVAL:-15}"
DEFAULT_MODEL="gpt-5.5"
IMPLEMENTATION_MODEL="gpt-5.4"
REVIEW_MODEL="gpt-5.5"
MAX_PARALLEL_REMEDIATION="6"
RETRY_COUNT="3"
RETRY_INITIAL_SECONDS="${AGILE_LOOP_RETRY_INITIAL_SECONDS:-${RALPH_LOOP_RETRY_INITIAL_SECONDS:-5}}"
DRY_RUN="0"
UNSAFE_BYPASS_APPROVALS="${AGILE_LOOP_UNSAFE_BYPASS:-0}"
CURRENT_TASK=""
CURRENT_ITERATION=""
CURRENT_STAGE=""

CODEX_BIN="${CODEX_BIN:-codex}"
GH_BIN="${GH_BIN:-gh}"
GIT_BIN="${GIT_BIN:-git}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage: agile-loop.sh [options]

Options:
  --repo PATH                 Repository to run in. Defaults to current directory.
  --base BRANCH               Base branch. Defaults to main.
  --max-iterations N          Maximum queued tasks to process. Defaults to 10.
  --poll-interval SECONDS     PR merge polling interval. Defaults to 60.
  --poll-timeout SECONDS      Stop polling after this many seconds. 0 means no timeout.
  --queue-glob GLOB           Queue glob relative to repo. Defaults to docs/agile-loop/tasks/*.md.
  --state-root PATH           State root relative to repo. Defaults to .agile-loop/runs.
  --status-file PATH          Dashboard status JSON path relative to repo. Defaults to .agile-loop/status.json.
  --default-model MODEL       Planning/default model. Defaults to gpt-5.5.
  --implementation-model M    Implementation model. Defaults to gpt-5.4.
  --review-model MODEL        Review/QA/ship model. Defaults to gpt-5.5.
  --max-parallel N            Max remediation sub-agents to request. Defaults to 6.
  --dry-run                   Print planned sessions without invoking the runner adapter or changing task status.
  --unsafe-bypass-approvals   Required for non-dry-run execution. Child sessions use approval/sandbox bypass.
  -h, --help                  Show this help.

Failed loop stages are retried 3 times with exponential backoff.
Default backoff is 5s, 10s, 20s; set AGILE_LOOP_RETRY_INITIAL_SECONDS to override the first delay.
RALPH_LOOP_RETRY_INITIAL_SECONDS is still accepted for backward compatibility.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --base) BASE="${2:-}"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="${2:-}"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="${2:-}"; shift 2 ;;
    --poll-timeout) POLL_TIMEOUT="${2:-}"; shift 2 ;;
    --queue-glob) QUEUE_GLOB="${2:-}"; shift 2 ;;
    --state-root) STATE_ROOT="${2:-}"; shift 2 ;;
    --status-file) STATUS_FILE="${2:-}"; shift 2 ;;
    --default-model) DEFAULT_MODEL="${2:-}"; shift 2 ;;
    --implementation-model) IMPLEMENTATION_MODEL="${2:-}"; shift 2 ;;
    --review-model) REVIEW_MODEL="${2:-}"; shift 2 ;;
    --max-parallel) MAX_PARALLEL_REMEDIATION="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="1"; shift ;;
    --unsafe-bypass-approvals) UNSAFE_BYPASS_APPROVALS="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] || REPO="$(pwd)"
[ -d "$REPO" ] || die "repo does not exist: $REPO"
command -v "$PYTHON_BIN" >/dev/null 2>&1 || die "python3 is required"
if [ "$DRY_RUN" != "1" ] && [ "$UNSAFE_BYPASS_APPROVALS" != "1" ]; then
  die "non-dry-run execution requires --unsafe-bypass-approvals or AGILE_LOOP_UNSAFE_BYPASS=1"
fi

cd "$REPO"
REPO="$(pwd)"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$STATE_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
LOG_FILE="$RUN_DIR/runner.log"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE" >&2
}

write_status() {
  local loop_status="$1"
  local stage="$2"
  local stage_status="$3"
  local message="$4"
  local task="${5:-$CURRENT_TASK}"
  local iteration="${6:-$CURRENT_ITERATION}"
  local pr_url="${7:-}"

  "$PYTHON_BIN" - \
    "$STATUS_FILE" \
    "$RUN_ID" \
    "$REPO" \
    "$BASE" \
    "$RUN_DIR" \
    "$LOG_FILE" \
    "$loop_status" \
    "$stage" \
    "$stage_status" \
    "$message" \
    "$task" \
    "$iteration" \
    "$pr_url" \
    "$DRY_RUN" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    status_file,
    run_id,
    repo,
    base,
    run_dir,
    log_file,
    loop_status,
    stage,
    stage_status,
    message,
    task,
    iteration,
    pr_url,
    dry_run,
) = sys.argv[1:]

repo_path = Path(repo).resolve()
status_path = Path(status_file)
if not status_path.is_absolute():
    status_path = repo_path / status_path

task_path = Path(task) if task else None
if task_path and not task_path.is_absolute():
    task_path = repo_path / task_path

task_title = ""
if task_path and task_path.exists():
    text = task_path.read_text(errors="ignore")
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            for line in text[4:end].splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                if key.strip() == "title":
                    task_title = value.strip().strip('"').strip("'")
                    break
    if not task_title:
        task_title = task_path.stem

iteration_value = int(iteration) if iteration.isdigit() else None
payload = {
    "run_id": run_id,
    "repo": str(repo_path),
    "base": base,
    "status": loop_status,
    "stage": stage,
    "stage_status": stage_status,
    "message": message,
    "task_file": str(task_path) if task_path else "",
    "task_title": task_title,
    "iteration": iteration_value,
    "pr_url": pr_url,
    "dry_run": dry_run == "1",
    "run_dir": str(Path(run_dir).resolve()),
    "log_file": str(Path(log_file).resolve()),
    "updated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}

status_path.parent.mkdir(parents=True, exist_ok=True)
tmp_path = status_path.with_name(f"{status_path.name}.{os.getpid()}.tmp")
tmp_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
tmp_path.replace(status_path)
PY
}

STATUS_HEARTBEAT_PID=""

start_status_heartbeat() {
  local loop_status="$1"
  local stage="$2"
  local stage_status="$3"
  local message="$4"
  local task="$5"
  local iteration="$6"
  local pr_url="${7:-}"

  (
    exec >/dev/null 2>&1
    while true; do
      sleep "$STATUS_HEARTBEAT_INTERVAL"
      write_status "$loop_status" "$stage" "$stage_status" "$message" "$task" "$iteration" "$pr_url" || true
    done
  ) &
  STATUS_HEARTBEAT_PID="$!"
}

stop_status_heartbeat() {
  local pid="$1"
  if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
}

retry_delay_for_attempt() {
  local retry_number="$1"
  local delay="$RETRY_INITIAL_SECONDS"
  local index
  index=1
  while [ "$index" -lt "$retry_number" ]; do
    delay=$((delay * 2))
    index=$((index + 1))
  done
  printf '%s\n' "$delay"
}

retry_with_backoff() {
  local label="$1"
  shift

  local retry_number rc delay
  retry_number=0
  while true; do
    rc=0
    "$@" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if [ "$retry_number" -gt 0 ]; then
        log "$label succeeded after $((retry_number + 1)) attempts"
      fi
      return 0
    fi

    if [ "$retry_number" -ge "$RETRY_COUNT" ]; then
      log "$label failed after $((RETRY_COUNT + 1)) attempts"
      return "$rc"
    fi

    retry_number=$((retry_number + 1))
    delay="$(retry_delay_for_attempt "$retry_number")"
    log "$label failed with exit $rc; retry $retry_number/$RETRY_COUNT in ${delay}s"
    write_status "running" "${CURRENT_STAGE:-retry}" "retrying" "$label failed with exit $rc; retry $retry_number/$RETRY_COUNT in ${delay}s" "$CURRENT_TASK" "$CURRENT_ITERATION"
    sleep "$delay"
  done
}

frontmatter_value() {
  local file="$1"
  local key="$2"
  "$PYTHON_BIN" - "$file" "$key" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
text = path.read_text()
if not text.startswith("---\n"):
    print("")
    raise SystemExit
end = text.find("\n---", 4)
if end == -1:
    print("")
    raise SystemExit
for line in text[4:end].splitlines():
    if ":" not in line:
        continue
    k, v = line.split(":", 1)
    if k.strip() == key:
        print(v.strip().strip('"').strip("'"))
        raise SystemExit
print("")
PY
}

set_frontmatter_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  "$PYTHON_BIN" - "$file" "$key" "$value" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text()
if not text.startswith("---\n"):
    text = "---\n---\n\n" + text
end = text.find("\n---", 4)
if end == -1:
    raise SystemExit(f"invalid frontmatter in {path}")
header = text[4:end].splitlines()
body = text[end:]
written = False
new_header = []
for line in header:
    if ":" in line and line.split(":", 1)[0].strip() == key:
        new_header.append(f"{key}: {value}")
        written = True
    else:
        new_header.append(line)
if not written:
    new_header.append(f"{key}: {value}")
path.write_text("---\n" + "\n".join(new_header).rstrip() + body)
PY
}

append_task_note() {
  local file="$1"
  local status="$2"
  local note="$3"
  "$PYTHON_BIN" - "$file" "$status" "$note" <<'PY'
import sys
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
status = sys.argv[2]
note = sys.argv[3]
text = path.read_text()
stamp = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
entry = f"\n\n## Agile Loop Notes\n\n- {stamp} [{status}] {note}\n"
path.write_text(text.rstrip() + entry)
PY
}

find_next_task() {
  local task
  for task in $QUEUE_GLOB; do
    [ -e "$task" ] || continue
    if [ "$(frontmatter_value "$task" status)" = "todo" ]; then
      printf '%s\n' "$task"
      return 0
    fi
  done
  return 1
}

task_title() {
  local task="$1"
  local title
  title="$(frontmatter_value "$task" title)"
  if [ -n "$title" ]; then
    printf '%s\n' "$title"
  else
    basename "$task" .md
  fi
}

json_int_from_last_line() {
  local file="$1"
  local key="$2"
  "$PYTHON_BIN" - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
for line in reversed(path.read_text(errors="ignore").splitlines()):
    line = line.strip()
    if not line.startswith("{") or not line.endswith("}"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    value = obj.get(key, 0)
    try:
        print(int(value))
    except Exception:
        print(0)
    raise SystemExit
print(0)
PY
}

json_string_from_last_line() {
  local file="$1"
  local key="$2"
  "$PYTHON_BIN" - "$file" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
for line in reversed(path.read_text(errors="ignore").splitlines()):
    line = line.strip()
    if not line.startswith("{") or not line.endswith("}"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    print(str(obj.get(key, "")))
    raise SystemExit
print("")
PY
}

has_json_last_line() {
  local file="$1"
  "$PYTHON_BIN" - "$file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    lines = path.read_text(errors="ignore").splitlines()
except Exception:
    raise SystemExit(1)

for line in reversed(lines):
    line = line.strip()
    if not line.startswith("{") or not line.endswith("}"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    raise SystemExit(0 if isinstance(obj, dict) else 1)
raise SystemExit(1)
PY
}

contains_blocked_status() {
  local file="$1"
  grep -Eq 'STATUS:[[:space:]]*(BLOCKED|NEEDS_CONTEXT)|"blocked"[[:space:]]*:[[:space:]]*true' "$file"
}

prompt_file_for_stage() {
  local iter_dir="$1"
  local stage="$2"
  printf '%s/%s.prompt.md\n' "$iter_dir" "$stage"
}

write_prompt() {
  local file="$1"
  local content="$2"
  printf '%s\n' "$content" > "$file"
}

stage_session_contract() {
  cat <<'EOF'
Session isolation:
This is a fresh Codex session for exactly this Agile Loop stage. Reconstruct all context from the repository, task file, and referenced stage output files. Do not rely on previous child-session chat history. Do not use codex resume.
EOF
}

run_codex_stage_once() {
  local stage="$1"
  local model="$2"
  local prompt_file="$3"
  local output_file="$4"
  local events_file="${output_file%.md}.events.log"

  CURRENT_STAGE="$stage"
  log "stage=$stage model=$model fresh_session=true output=$output_file"
  write_status "running" "$stage" "running" "running $stage with $model" "$CURRENT_TASK" "$CURRENT_ITERATION"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN: would run fresh codex session stage=$stage model=$model prompt=$prompt_file"
    write_status "dry_run" "$stage" "skipped" "dry-run skipped $stage" "$CURRENT_TASK" "$CURRENT_ITERATION"
    return 0
  fi

  # Each stage is isolated; handoff must happen through prompt, repo, and output files.
  rm -f "$output_file"
  local rc heartbeat_pid
  start_status_heartbeat "running" "$stage" "running" "running $stage with $model" "$CURRENT_TASK" "$CURRENT_ITERATION"
  heartbeat_pid="$STATUS_HEARTBEAT_PID"
  rc=0
  "$CODEX_BIN" exec \
    -C "$REPO" \
    -m "$model" \
    --dangerously-bypass-approvals-and-sandbox \
    --ephemeral \
    -o "$output_file" \
    - < "$prompt_file" > "$events_file" 2>&1 || rc=$?
  stop_status_heartbeat "$heartbeat_pid"
  if [ "$rc" -ne 0 ]; then
    log "stage=$stage failed; see $events_file"
    write_status "running" "$stage" "failed" "$stage failed; see $events_file" "$CURRENT_TASK" "$CURRENT_ITERATION"
    return "$rc"
  fi
  if [ ! -s "$output_file" ]; then
    log "stage=$stage produced no output"
    write_status "running" "$stage" "failed" "$stage produced no output" "$CURRENT_TASK" "$CURRENT_ITERATION"
    return 1
  fi
  write_status "running" "$stage" "completed" "completed $stage" "$CURRENT_TASK" "$CURRENT_ITERATION"
}

mark_blocked_and_stop() {
  local task="$1"
  local message="$2"
  write_status "blocked" "${CURRENT_STAGE:-blocked}" "blocked" "$message" "$task" "$CURRENT_ITERATION"
  if [ "$DRY_RUN" != "1" ]; then
    set_frontmatter_value "$task" status blocked
    append_task_note "$task" blocked "$message"
  fi
  log "BLOCKED: $message"
  exit 1
}

poll_until_merged() {
  local task="$1"
  local pr_url="$2"
  local start
  CURRENT_STAGE="poll-merge"
  start="$(date +%s)"

  if [ "$DRY_RUN" = "1" ]; then
    write_status "dry_run" "poll-merge" "skipped" "dry-run would poll PR until merged" "$task" "$CURRENT_ITERATION" "$pr_url"
    echo "DRY RUN: would poll PR until merged: ${pr_url:-current branch PR}"
    return 0
  fi

  command -v "$GH_BIN" >/dev/null 2>&1 || mark_blocked_and_stop "$task" "gh is required to poll PR merge state"
  write_status "waiting" "poll-merge" "waiting" "waiting for human merge; url=${pr_url:-unknown}" "$task" "$CURRENT_ITERATION" "$pr_url"

  while true; do
    local state merged_at now elapsed
    state="$("$GH_BIN" pr view --json state -q .state 2>/dev/null || true)"
    merged_at="$("$GH_BIN" pr view --json mergedAt -q .mergedAt 2>/dev/null || true)"
    if [ "$state" = "MERGED" ] || { [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; }; then
      log "PR merged: ${pr_url:-current branch PR}"
      write_status "running" "poll-merge" "completed" "PR merged: ${pr_url:-current branch PR}" "$task" "$CURRENT_ITERATION" "$pr_url"
      return 0
    fi
    if [ "$state" = "CLOSED" ]; then
      mark_blocked_and_stop "$task" "PR was closed without merge"
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$POLL_TIMEOUT" != "0" ] && [ "$elapsed" -ge "$POLL_TIMEOUT" ]; then
      mark_blocked_and_stop "$task" "timed out waiting for PR merge after ${POLL_TIMEOUT}s"
    fi
    log "waiting for human merge; state=${state:-unknown}; url=${pr_url:-unknown}"
    write_status "waiting" "poll-merge" "waiting" "waiting for human merge; state=${state:-unknown}; url=${pr_url:-unknown}" "$task" "$CURRENT_ITERATION" "$pr_url"
    sleep "$POLL_INTERVAL"
  done
}

git_operation_in_progress() {
  local state
  local path

  for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    path="$("$GIT_BIN" rev-parse --git-path "$state" 2>/dev/null || true)"
    if [ -n "$path" ] && [ -e "$path" ]; then
      printf '%s\n' "$state"
      return 0
    fi
  done

  return 1
}

sync_base_after_merge() {
  local task="$1"
  local git_state=""
  local remote_ref="refs/remotes/origin/$BASE"
  local fetch_ref="+refs/heads/$BASE:$remote_ref"
  CURRENT_STAGE="sync-base"

  if [ "$DRY_RUN" = "1" ]; then
    write_status "dry_run" "sync-base" "skipped" "dry-run would sync $BASE with origin/$BASE using fetch and fast-forward" "$task" "$CURRENT_ITERATION"
    echo "DRY RUN: would run git fetch origin $fetch_ref && git switch $BASE && git merge --ff-only $remote_ref"
    return 0
  fi

  command -v "$GIT_BIN" >/dev/null 2>&1 || mark_blocked_and_stop "$task" "git is required to sync $BASE after PR merge"
  write_status "running" "sync-base" "running" "syncing $BASE with origin/$BASE using fetch and fast-forward" "$task" "$CURRENT_ITERATION"

  git_state="$(git_operation_in_progress || true)"
  if [ -n "$git_state" ]; then
    mark_blocked_and_stop "$task" "cannot sync $BASE while git operation is in progress ($git_state); resolve or abort it first"
  fi

  if ! "$GIT_BIN" fetch origin "$fetch_ref"; then
    mark_blocked_and_stop "$task" "failed to fetch origin/$BASE before post-merge sync"
  fi

  if ! "$GIT_BIN" switch "$BASE"; then
    mark_blocked_and_stop "$task" "failed to switch to $BASE before post-merge sync"
  fi

  if ! "$GIT_BIN" merge --ff-only "$remote_ref"; then
    mark_blocked_and_stop "$task" "failed to fast-forward $BASE to origin/$BASE; local $BASE has commits not on origin/$BASE or conflicting worktree state"
  fi

  log "synced $BASE with origin/$BASE using fetch and fast-forward"
  write_status "running" "sync-base" "completed" "synced $BASE with origin/$BASE using fetch and fast-forward" "$task" "$CURRENT_ITERATION"
}

build_plan_prompt() {
  local task="$1"
  cat <<EOF
You are running agile-loop stage: plan.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Read AGENTS.md and the task file first. Use the Superpowers writing-plans skill to convert the task into a decision-complete implementation plan. Save the plan in the repo's normal Superpowers plan location unless the task file specifies a stronger location.

Stop with BLOCKED if the task lacks enough objective or acceptance context to plan safely.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
EOF
}

build_implement_prompt() {
  local task="$1"
  cat <<EOF
You are running agile-loop stage: implement.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Use superpowers:subagent-driven-development to execute the current Superpowers plan task-by-task. Keep changes scoped to the plan. Run the plan's verification commands. Do not ship or create a PR.

Stop with BLOCKED if tests fail and cannot be fixed inside the task scope, if mandatory user judgment is needed, or if the plan is missing.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
EOF
}

build_coderabbit_prompt() {
  local task="$1"
  local pass="$2"
  cat <<EOF
You are running agile-loop stage: coderabbit review pass $pass.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Use coderabbit:code-review. Run CodeRabbit against the current branch, passing AGENTS.md as review context when available. Do not apply fixes in this stage.

Summarize issues by severity. The final line of your response must be exactly one JSON object:
{"critical":0,"major":0,"minor":0,"blocked":false,"summary":"short summary"}
EOF
}

build_coderabbit_remediation_prompt() {
  local task="$1"
  local review_output="$2"
  cat <<EOF
You are running agile-loop stage: remediate coderabbit.

Repository: $REPO
Base branch: $BASE
Task file: $task
Review output file: $review_output
Maximum remediation sub-agents: $MAX_PARALLEL_REMEDIATION

$(stage_session_contract)

Read the CodeRabbit output. Only if it contains Critical or Major issues, spawn scoped sub-agents to fix those issues. Keep each sub-agent's write scope disjoint and tied to one finding or file group. Do not fix Minor issues unless they are necessary for a Critical or Major fix.

Run targeted validation for the changed files. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
EOF
}

build_review_prompt() {
  local task="$1"
  cat <<EOF
You are running agile-loop stage: gstack review.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Use /review. Apply auto-fixes and handle the workflow exactly as the skill requires. Stop with BLOCKED if /review needs mandatory human judgment.
End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
EOF
}

build_qa_prompt() {
  local task="$1"
  cat <<EOF
You are running agile-loop stage: qa-only full.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Use /qa-only with mode: full. This stage is report-only: do not fix. Prefer the running local app and the task/plan verification steps. Include paths to the QA report.

The final line of your response must be exactly one JSON object:
{"issues":0,"blocked":false,"report":"path or short summary"}
EOF
}

build_qa_remediation_prompt() {
  local task="$1"
  local qa_output="$2"
  cat <<EOF
You are running agile-loop stage: remediate qa.

Repository: $REPO
Base branch: $BASE
Task file: $task
QA output file: $qa_output
Maximum remediation sub-agents: $MAX_PARALLEL_REMEDIATION

$(stage_session_contract)

Read the QA report. Only if it contains issues, spawn scoped sub-agents using /investigate to root-cause and fix them. Keep each fix scoped to a reproducible QA issue.

Rerun the relevant validation for fixed issues. End with:
STATUS: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
EOF
}

build_ship_prompt() {
  local task="$1"
  cat <<EOF
You are running agile-loop stage: ship.

Repository: $REPO
Base branch: $BASE
Task file: $task

$(stage_session_contract)

Use /ship. Run the full ship workflow. Stop with BLOCKED if tests fail, review requires human judgment, auth is missing, or the PR cannot be created.

The final line of your response must be exactly one JSON object:
{"blocked":false,"pr_url":"https://github.com/owner/repo/pull/123","summary":"short ship summary"}
EOF
}

run_status_stage_attempt() {
  local task="$1"
  local stage="$2"
  local model="$3"
  local prompt_file="$4"
  local output_file="$5"
  local rc

  run_codex_stage_once "$stage" "$model" "$prompt_file" "$output_file" || {
    rc=$?
    return "$rc"
  }
  if contains_blocked_status "$output_file"; then
    mark_blocked_and_stop "$task" "$stage session reported blocked or needs context"
  fi
}

run_status_stage() {
  local task="$1"
  local iter_dir="$2"
  local stage="$3"
  local model="$4"
  local prompt="$5"
  local prompt_file output_file
  prompt_file="$(prompt_file_for_stage "$iter_dir" "$stage")"
  output_file="$iter_dir/$stage.output.md"
  write_prompt "$prompt_file" "$prompt"

  if ! retry_with_backoff "$stage session" run_status_stage_attempt "$task" "$stage" "$model" "$prompt_file" "$output_file"; then
    mark_blocked_and_stop "$task" "$stage session failed after $RETRY_COUNT retries"
  fi
}

run_json_stage_attempt() {
  local task="$1"
  local stage="$2"
  local model="$3"
  local prompt_file="$4"
  local output_file="$5"
  local rc

  run_codex_stage_once "$stage" "$model" "$prompt_file" "$output_file" || {
    rc=$?
    return "$rc"
  }
  if contains_blocked_status "$output_file"; then
    mark_blocked_and_stop "$task" "$stage session reported blocked"
  fi
  if ! has_json_last_line "$output_file"; then
    log "stage=$stage missing final JSON line"
    write_status "running" "$stage" "failed" "$stage did not produce final JSON line" "$CURRENT_TASK" "$CURRENT_ITERATION"
    return 1
  fi
}

run_json_stage() {
  local task="$1"
  local iter_dir="$2"
  local stage="$3"
  local model="$4"
  local prompt="$5"
  local prompt_file output_file
  prompt_file="$(prompt_file_for_stage "$iter_dir" "$stage")"
  output_file="$iter_dir/$stage.output.md"
  write_prompt "$prompt_file" "$prompt"

  if ! retry_with_backoff "$stage JSON session" run_json_stage_attempt "$task" "$stage" "$model" "$prompt_file" "$output_file"; then
    mark_blocked_and_stop "$task" "$stage JSON session failed after $RETRY_COUNT retries"
  fi
  printf '%s\n' "$output_file"
}

run_iteration() {
  local task="$1"
  local iteration="$2"
  local iter_dir="$RUN_DIR/iteration-$iteration"
  mkdir -p "$iter_dir"
  CURRENT_TASK="$task"
  CURRENT_ITERATION="$iteration"
  CURRENT_STAGE="claim"

  log "claiming task: $task ($(task_title "$task"))"
  write_status "running" "claim" "running" "claiming task: $(task_title "$task")" "$task" "$iteration"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY RUN: next task $task"
    echo "DRY RUN: would run plan -> implement -> coderabbit -> conditional remediation -> review -> qa -> conditional investigate -> coderabbit -> conditional remediation -> ship -> poll merge -> sync base"
    write_status "dry_run" "dry-run" "completed" "dry-run printed planned sessions for $(task_title "$task")" "$task" "$iteration"
    return 0
  fi

  retry_with_backoff "claim task status update" set_frontmatter_value "$task" status doing || mark_blocked_and_stop "$task" "failed to mark task as doing after $RETRY_COUNT retries"
  retry_with_backoff "claim task note append" append_task_note "$task" doing "claimed by agile-loop run $RUN_ID iteration $iteration" || mark_blocked_and_stop "$task" "failed to append task claim note after $RETRY_COUNT retries"

  run_status_stage "$task" "$iter_dir" "01-plan" "$DEFAULT_MODEL" "$(build_plan_prompt "$task")"
  run_status_stage "$task" "$iter_dir" "02-implement" "$IMPLEMENTATION_MODEL" "$(build_implement_prompt "$task")"

  local cr1 cr1_critical cr1_major
  cr1="$(run_json_stage "$task" "$iter_dir" "03-coderabbit-pass-1" "$REVIEW_MODEL" "$(build_coderabbit_prompt "$task" "1")")"
  cr1_critical="$(json_int_from_last_line "$cr1" critical)"
  cr1_major="$(json_int_from_last_line "$cr1" major)"
  if [ $((cr1_critical + cr1_major)) -gt 0 ]; then
    run_status_stage "$task" "$iter_dir" "04-remediate-coderabbit-pass-1" "$REVIEW_MODEL" "$(build_coderabbit_remediation_prompt "$task" "$cr1")"
  else
    log "CodeRabbit pass 1 has no Critical/Major issues; skipping remediation"
    write_status "running" "04-remediate-coderabbit-pass-1" "skipped" "CodeRabbit pass 1 has no Critical/Major issues; skipping remediation" "$task" "$iteration"
  fi

  run_status_stage "$task" "$iter_dir" "05-gstack-review" "$REVIEW_MODEL" "$(build_review_prompt "$task")"

  local qa qa_issues
  qa="$(run_json_stage "$task" "$iter_dir" "06-qa-only-full" "$REVIEW_MODEL" "$(build_qa_prompt "$task")")"
  qa_issues="$(json_int_from_last_line "$qa" issues)"
  if [ "$qa_issues" -gt 0 ]; then
    run_status_stage "$task" "$iter_dir" "07-remediate-qa" "$REVIEW_MODEL" "$(build_qa_remediation_prompt "$task" "$qa")"
  else
    log "QA reported 0 issues; skipping investigate remediation"
    write_status "running" "07-remediate-qa" "skipped" "QA reported 0 issues; skipping investigate remediation" "$task" "$iteration"
  fi

  local cr2 cr2_critical cr2_major
  cr2="$(run_json_stage "$task" "$iter_dir" "08-coderabbit-pass-2" "$REVIEW_MODEL" "$(build_coderabbit_prompt "$task" "2")")"
  cr2_critical="$(json_int_from_last_line "$cr2" critical)"
  cr2_major="$(json_int_from_last_line "$cr2" major)"
  if [ $((cr2_critical + cr2_major)) -gt 0 ]; then
    run_status_stage "$task" "$iter_dir" "09-remediate-coderabbit-pass-2" "$REVIEW_MODEL" "$(build_coderabbit_remediation_prompt "$task" "$cr2")"
  else
    log "CodeRabbit pass 2 has no Critical/Major issues; skipping remediation"
    write_status "running" "09-remediate-coderabbit-pass-2" "skipped" "CodeRabbit pass 2 has no Critical/Major issues; skipping remediation" "$task" "$iteration"
  fi

  local ship pr_url
  ship="$(run_json_stage "$task" "$iter_dir" "10-ship" "$REVIEW_MODEL" "$(build_ship_prompt "$task")")"
  pr_url="$(json_string_from_last_line "$ship" pr_url)"
  poll_until_merged "$task" "$pr_url"
  sync_base_after_merge "$task"

  retry_with_backoff "done task status update" set_frontmatter_value "$task" status "done" || mark_blocked_and_stop "$task" "failed to mark task as done after $RETRY_COUNT retries"
  retry_with_backoff "done task note append" append_task_note "$task" "done" "PR merged: ${pr_url:-current branch PR}" || mark_blocked_and_stop "$task" "failed to append task done note after $RETRY_COUNT retries"
  log "task done: $task"
  write_status "done" "complete" "completed" "task done: $(task_title "$task")" "$task" "$iteration" "$pr_url"
}

main() {
  log "agile-loop start repo=$REPO base=$BASE max_iterations=$MAX_ITERATIONS queue=$QUEUE_GLOB"
  write_status "running" "start" "running" "agile-loop started" "" ""
  local iteration task
  iteration=1
  while [ "$iteration" -le "$MAX_ITERATIONS" ]; do
    if ! task="$(find_next_task)"; then
      log "no todo tasks found"
      write_status "idle" "idle" "idle" "no todo tasks found" "$CURRENT_TASK" "$CURRENT_ITERATION"
      exit 0
    fi
    run_iteration "$task" "$iteration"
    iteration=$((iteration + 1))
  done
  log "max iterations reached: $MAX_ITERATIONS"
  write_status "completed" "complete" "completed" "max iterations reached: $MAX_ITERATIONS" "$CURRENT_TASK" "$CURRENT_ITERATION"
}

main
