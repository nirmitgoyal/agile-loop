#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="$SKILL_DIR/scripts/agile-dashboard.py"
TMP_ROOT="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  if grep -q "$pattern" "$file"; then
    echo "unexpected match for '$pattern' in $file" >&2
    exit 1
  fi
}

repo="$TMP_ROOT/repo"
mkdir -p "$repo/.agile-loop"
mkdir -p "$repo/docs/agile-loop/tasks"
cat > "$repo/.agile-loop/status.json" <<'EOF'
{
  "base": "main",
  "message": "running 01-plan",
  "repo": "fixture",
  "run_id": "test-run",
  "stage": "01-plan",
  "stage_status": "running",
  "status": "running",
  "task_title": "Fixture task",
  "updated_at": "2026-05-29T00:00:00Z"
}
EOF
cat > "$repo/docs/agile-loop/tasks/01-active.md" <<'EOF'
---
status: todo
title: Active task
---

## Objective
Keep this task in the queue.
EOF
cat > "$repo/docs/agile-loop/tasks/02-done.md" <<'EOF'
---
status: done
title: Finished task
---

## Objective
Exclude this task from the dashboard queue.
EOF
cat > "$repo/docs/agile-loop/tasks/04-done.md" <<'EOF'
---
status: done
title: Done task 04
---
EOF
cat > "$repo/docs/agile-loop/tasks/05-done.md" <<'EOF'
---
status: done
title: Done task 05
---
EOF
cat > "$repo/docs/agile-loop/tasks/06-done.md" <<'EOF'
---
status: done
title: Done task 06
---
EOF
cat > "$repo/docs/agile-loop/tasks/07-done.md" <<'EOF'
---
status: done
title: Done task 07
---
EOF
cat > "$repo/docs/agile-loop/tasks/08-done.md" <<'EOF'
---
status: done
title: Done task 08
---
EOF
cat > "$repo/docs/agile-loop/tasks/03-blocked.md" <<'EOF'
---
status: blocked
title: Blocked task
---

## Objective
Show the blocker.

## Agile Loop Notes

- 2026-05-29T00:00:00Z [blocked] Needs user answer
EOF
cat > "$repo/docs/agile-loop/tasks/09-unreadable.md" <<'EOF'
---
status: todo
title: Unreadable task
---
EOF
chmod 000 "$repo/docs/agile-loop/tasks/09-unreadable.md"

python3 - "$DASHBOARD" "$repo" <<'PY'
import importlib.util
import sys
from pathlib import Path

dashboard = Path(sys.argv[1])
repo = Path(sys.argv[2])
missing = repo / "docs/agile-loop/tasks/99-vanished.md"
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("agile_dashboard", dashboard)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

module.task_paths = lambda _repo, _queue_glob: [missing]
assert module.load_queue(repo, "unused") == []
assert module.load_past_work(repo, "unused") == []
assert module.blocked_reason_from_task(missing) == ""
PY

"$DASHBOARD" --repo "$repo" --port 0 > "$TMP_ROOT/server.out" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 50); do
  if grep -q "Agile Loop dashboard:" "$TMP_ROOT/server.out"; then
    break
  fi
  sleep 0.1
done

if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
  cat "$TMP_ROOT/server.out" >&2
  echo "dashboard server exited unexpectedly" >&2
  exit 1
fi

url="$(awk '/Agile Loop dashboard:/ {print $4; exit}' "$TMP_ROOT/server.out")"
[ -n "$url" ] || {
  cat "$TMP_ROOT/server.out" >&2
  echo "dashboard URL was not printed" >&2
  exit 1
}

python3 - "$url/api/status" "$TMP_ROOT/status.out" <<'PY'
import sys
from pathlib import Path
from urllib.request import urlopen

body = urlopen(sys.argv[1], timeout=5).read().decode()
Path(sys.argv[2]).write_text(body)
PY

python3 - "$url/" "$TMP_ROOT/index.out" <<'PY'
import sys
from pathlib import Path
from urllib.request import urlopen

body = urlopen(sys.argv[1], timeout=5).read().decode()
Path(sys.argv[2]).write_text(body)
PY

python3 - "$url/api/events" "$TMP_ROOT/events.out" <<'PY'
import sys
from pathlib import Path
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=5) as response:
    chunk = b""
    while b"\n\n" not in chunk:
        chunk += response.read(1)

Path(sys.argv[2]).write_bytes(chunk)
PY

grep -q '"status": "running"' "$TMP_ROOT/status.out"
grep -q '"stage": "01-plan"' "$TMP_ROOT/status.out"
grep -q '^data: ' "$TMP_ROOT/events.out"
python3 - "$TMP_ROOT/status.out" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
titles = [item["title"] for item in data["queue"]]
assert "Active task" in titles
assert "Blocked task" in titles
assert "Finished task" not in titles
assert "Unreadable task" not in titles
past_work_titles = [item["title"] for item in data["past_work"]]
assert past_work_titles == [
    "Done task 08",
    "Done task 07",
    "Done task 06",
    "Done task 05",
    "Done task 04",
]
assert "Finished task" not in past_work_titles
assert "Active task" not in past_work_titles
assert "Unreadable task" not in past_work_titles
blocked = next(item for item in data["queue"] if item["title"] == "Blocked task")
assert blocked["blocked_reason"] == "Needs user answer"
PY
grep -q 'const POLL_INTERVAL_MS = 15000;' "$TMP_ROOT/index.out"
grep -q 'new EventSource("/api/events")' "$TMP_ROOT/index.out"
grep -q 'new Intl.DateTimeFormat(undefined,' "$TMP_ROOT/index.out"
grep -q 'hour: "numeric"' "$TMP_ROOT/index.out"
assert_not_contains 'timeZoneName:' "$TMP_ROOT/index.out"
assert_not_contains 'poll #' "$TMP_ROOT/index.out"
grep -q '>Queue<' "$TMP_ROOT/index.out"
grep -q '>Current Status<' "$TMP_ROOT/index.out"
grep -q '>Current Stage<' "$TMP_ROOT/index.out"
assert_not_contains '>Runner Updated<' "$TMP_ROOT/index.out"
grep -q '>Last Poll<' "$TMP_ROOT/index.out"
grep -q '>Past Work<' "$TMP_ROOT/index.out"
grep -q '<details class="panel" open>' "$TMP_ROOT/index.out"
grep -q 'id="pastWork"' "$TMP_ROOT/index.out"
grep -q 'renderPastWork(data.past_work);' "$TMP_ROOT/index.out"
assert_not_contains '>Browser Time Zone<' "$TMP_ROOT/index.out"
grep -q '>Blocked<' "$TMP_ROOT/index.out"
assert_not_contains '>Iteration<' "$TMP_ROOT/index.out"
assert_not_contains '>Details<' "$TMP_ROOT/index.out"

echo "agile-loop dashboard tests passed"
