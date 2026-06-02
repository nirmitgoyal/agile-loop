#!/usr/bin/env python3
"""Serve a tiny Agile Loop status dashboard."""

from __future__ import annotations

import argparse
import glob
import json
import sys
import time
import webbrowser
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Optional
from urllib.parse import urlparse


POLL_INTERVAL_MS = 15000
PAST_WORK_LIMIT = 5


HTML = r"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Agile Loop Dashboard</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f7f8fa;
      color: #16181d;
    }

    body {
      margin: 0;
      min-height: 100vh;
      background: #f7f8fa;
    }

    main {
      width: min(960px, calc(100vw - 32px));
      margin: 0 auto;
      padding: 32px 0;
    }

    h1 {
      margin: 0 0 20px;
      font-size: 28px;
      line-height: 1.1;
    }

    .badge {
      border: 1px solid #c9ced8;
      border-radius: 999px;
      padding: 6px 12px;
      font-size: 13px;
      font-weight: 700;
      text-transform: uppercase;
      background: #fff;
    }

    .badge.running,
    .badge.waiting {
      border-color: #2f6fed;
      color: #1f57c3;
      background: #eef4ff;
    }

    .badge.blocked,
    .badge.error {
      border-color: #c93636;
      color: #a12222;
      background: #fff1f1;
    }

    .badge.done,
    .badge.completed,
    .badge.idle {
      border-color: #2f855a;
      color: #276749;
      background: #eefbf3;
    }

    .panel {
      border: 1px solid #d9dde5;
      border-radius: 8px;
      background: #fff;
      padding: 20px;
      margin-bottom: 16px;
      box-shadow: 0 1px 2px rgba(16, 24, 40, 0.05);
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 16px;
    }

    .label {
      margin: 0 0 6px;
      color: #667085;
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    .value {
      margin: 0;
      font-size: 15px;
      line-height: 1.35;
      overflow-wrap: anywhere;
    }

    .queue {
      display: grid;
      gap: 10px;
      margin: 0;
      padding: 0;
      list-style: none;
    }

    .queue-item {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 12px;
      align-items: center;
      border-top: 1px solid #e4e7ee;
      padding-top: 10px;
    }

    .queue-item:first-child {
      border-top: 0;
      padding-top: 0;
    }

    .queue-title {
      margin: 0;
      overflow-wrap: anywhere;
    }

    .queue-item .badge {
      justify-self: start;
    }

    .summary-label {
      cursor: pointer;
      list-style: none;
    }

    .summary-label::-webkit-details-marker {
      display: none;
    }

    .summary-label::after {
      content: "Show";
      float: right;
      color: #16181d;
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    details[open] .summary-label::after {
      content: "Hide";
    }

    .blocked-panel {
      border-color: #c93636;
      background: #fff7f7;
    }

    [hidden] {
      display: none !important;
    }

    @media (max-width: 760px) {
      main {
        width: min(100vw - 20px, 960px);
        padding: 20px 0;
      }

      .grid {
        grid-template-columns: 1fr;
      }

      .queue-item {
        grid-template-columns: 1fr;
      }
    }

    @media (prefers-color-scheme: dark) {
      :root,
      body {
        background: #101318;
        color: #eef2f8;
      }

      .panel,
      .badge {
        background: #171b22;
        border-color: #333947;
      }

      .label {
        color: #9aa4b2;
      }

      .summary-label::after {
        color: #eef2f8;
      }

      .queue-item {
        border-top-color: #2a303c;
      }

      .blocked-panel {
        background: #231719;
        border-color: #5b2427;
      }
    }
  </style>
</head>
<body>
  <main>
    <h1>Agile Loop</h1>

    <section class="panel" aria-live="polite">
      <p class="label">Queue</p>
      <ul id="queue" class="queue">
        <li class="value">Loading</li>
      </ul>
    </section>

    <details class="panel" open>
      <summary class="label summary-label">Past Work</summary>
      <ul id="pastWork" class="queue">
        <li class="value">Loading</li>
      </ul>
    </details>

    <section class="grid" aria-live="polite">
      <article class="panel">
        <p class="label">Current Status</p>
        <p id="currentStatus" class="value">-</p>
      </article>
      <article class="panel">
        <p class="label">Current Stage</p>
        <p id="currentStage" class="value">-</p>
      </article>
      <article class="panel">
        <p class="label">Last Poll</p>
        <p id="refreshedAt" class="value">-</p>
      </article>
      <article id="blockedPanel" class="panel blocked-panel" hidden>
        <p class="label">Blocked</p>
        <p id="blockedReason" class="value">-</p>
      </article>
    </section>
  </main>

  <script>
    const POLL_INTERVAL_MS = __POLL_INTERVAL_MS__;
    const localTimeFormatter = new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
      second: "2-digit",
    });

    function valueOrDash(value) {
      if (value === null || value === undefined || value === "") return "-";
      return String(value);
    }

    function setText(id, value) {
      document.getElementById(id).textContent = valueOrDash(value);
    }

    function formatLocalTime(value) {
      if (!value) return "-";
      const date = value instanceof Date ? value : new Date(value);
      if (Number.isNaN(date.getTime())) return valueOrDash(value);
      return localTimeFormatter.format(date);
    }

    function renderTaskList(elementId, tasks, emptyText) {
      const listElement = document.getElementById(elementId);
      listElement.replaceChildren();

      if (!Array.isArray(tasks) || tasks.length === 0) {
        const item = document.createElement("li");
        item.className = "value";
        item.textContent = emptyText;
        listElement.appendChild(item);
        return;
      }

      tasks.forEach((task) => {
        const item = document.createElement("li");
        item.className = "queue-item";

        const title = document.createElement("p");
        title.className = "queue-title value";
        title.textContent = valueOrDash(task.title || task.file);

        const status = document.createElement("span");
        const statusText = valueOrDash(task.status).toLowerCase();
        status.className = "badge " + statusText;
        status.textContent = statusText;

        item.append(title, status);
        listElement.appendChild(item);
      });
    }

    function renderQueue(queue) {
      renderTaskList("queue", queue, "No queued tasks.");
    }

    function renderPastWork(pastWork) {
      renderTaskList("pastWork", pastWork, "No past work.");
    }

    function blockedReason(data) {
      const status = valueOrDash(data.status).toLowerCase();
      const stageStatus = valueOrDash(data.stage_status).toLowerCase();
      const isBlocked = status === "blocked" || stageStatus === "blocked";
      if (isBlocked && data.message) return valueOrDash(data.message);

      const blockedTask = Array.isArray(data.queue)
        ? data.queue.find((task) => valueOrDash(task.status).toLowerCase() === "blocked")
        : null;
      if (!blockedTask) return isBlocked ? "Blocked without a recorded reason." : "";
      return blockedTask.blocked_reason || `${valueOrDash(blockedTask.title || blockedTask.file)} is blocked.`;
    }

    function render(data) {
      const status = valueOrDash(data.status).toLowerCase();
      renderQueue(data.queue);
      renderPastWork(data.past_work);
      setText("currentStatus", status);
      setText("currentStage", data.stage);
      setText("refreshedAt", formatLocalTime(new Date()));

      const reason = blockedReason(data);
      const blockedPanel = document.getElementById("blockedPanel");
      blockedPanel.hidden = !reason || reason === "-";
      setText("blockedReason", reason);

      document.title = "Agile Loop - " + status;
    }

    async function loadStatus() {
      try {
        const response = await fetch("/api/status?ts=" + encodeURIComponent(Date.now()), { cache: "no-store" });
        render(await response.json());
      } catch (error) {
        render({
          status: "error",
          stage: "dashboard",
          stage_status: "failed",
          message: String(error),
        });
      }
    }

    function startPollingFallback() {
      loadStatus();
      setInterval(loadStatus, POLL_INTERVAL_MS);
    }

    if ("EventSource" in window) {
      const events = new EventSource("/api/events");
      events.onmessage = (event) => {
        render(JSON.parse(event.data));
      };
      events.onerror = () => {
        events.close();
        startPollingFallback();
      };
    } else {
      startPollingFallback();
    }
  </script>
</body>
</html>
""".replace("__POLL_INTERVAL_MS__", str(POLL_INTERVAL_MS))


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def resolve_status_path(repo: Path, status_file: str) -> Path:
    path = Path(status_file)
    if path.is_absolute():
        return path
    return repo / path


def task_paths(repo: Path, queue_glob: str) -> list[Path]:
    pattern = queue_glob if Path(queue_glob).is_absolute() else str(repo / queue_glob)
    return sorted(Path(path) for path in glob.glob(pattern) if Path(path).is_file())


def read_frontmatter(path: Path) -> Optional[dict[str, str]]:
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return None

    if not text.startswith("---\n"):
        return {}

    end = text.find("\n---", 4)
    if end == -1:
        return {}

    values: dict[str, str] = {}
    for line in text[4:end].splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def blocked_reason_from_task(path: Path) -> str:
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        return ""

    for line in reversed(text.splitlines()):
        if "[blocked]" not in line:
            continue
        return line.split("[blocked]", 1)[1].strip()
    return ""


def load_queue(repo: Path, queue_glob: str) -> list[dict[str, str]]:
    queue: list[dict[str, str]] = []
    for path in task_paths(repo, queue_glob):
        metadata = read_frontmatter(path)
        if metadata is None:
            continue
        status = metadata.get("status", "unknown")
        if status == "done":
            continue

        item = {
            "file": str(path),
            "title": metadata.get("title") or path.stem,
            "status": status,
        }
        if status == "blocked":
            item["blocked_reason"] = blocked_reason_from_task(path)
        queue.append(item)
    return queue


def load_past_work(repo: Path, queue_glob: str) -> list[dict[str, str]]:
    past_work: list[dict[str, str]] = []
    for path in reversed(task_paths(repo, queue_glob)):
        metadata = read_frontmatter(path)
        if metadata is None:
            continue
        status = metadata.get("status", "unknown")
        if status != "done":
            continue

        past_work.append(
            {
                "file": str(path),
                "title": metadata.get("title") or path.stem,
                "status": status,
            }
        )
        if len(past_work) == PAST_WORK_LIMIT:
            break
    return past_work


def add_queue(data: dict[str, Any], repo: Path, queue_glob: str) -> dict[str, Any]:
    data["queue"] = load_queue(repo, queue_glob)
    data["past_work"] = load_past_work(repo, queue_glob)
    return data


def load_status(repo: Path, status_path: Path, queue_glob: str) -> dict[str, Any]:
    if not status_path.exists():
        return add_queue(
            {
                "status": "missing",
                "stage": "dashboard",
                "stage_status": "waiting",
                "message": f"Status file not found: {status_path}",
                "repo": str(repo),
                "updated_at": utc_now(),
            },
            repo,
            queue_glob,
        )

    try:
        data = json.loads(status_path.read_text())
    except Exception as exc:
        return add_queue(
            {
                "status": "error",
                "stage": "dashboard",
                "stage_status": "failed",
                "message": f"Could not read status file: {exc}",
                "repo": str(repo),
                "updated_at": utc_now(),
            },
            repo,
            queue_glob,
        )

    if not isinstance(data, dict):
        return add_queue(
            {
                "status": "error",
                "stage": "dashboard",
                "stage_status": "failed",
                "message": "Status file did not contain a JSON object.",
                "repo": str(repo),
                "updated_at": utc_now(),
            },
            repo,
            queue_glob,
        )

    data.setdefault("repo", str(repo))
    data.setdefault("updated_at", "")
    data.setdefault("status", "unknown")
    data.setdefault("stage", "unknown")
    data.setdefault("stage_status", "unknown")
    data.setdefault("message", "")
    return add_queue(data, repo, queue_glob)


def make_handler(repo: Path, status_path: Path, queue_glob: str) -> type[BaseHTTPRequestHandler]:
    class DashboardHandler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path in {"/", "/index.html"}:
                self.send_payload("text/html; charset=utf-8", HTML.encode("utf-8"))
                return
            if path in {"/api/status", "/status"}:
                payload = json.dumps(load_status(repo, status_path, queue_glob), indent=2, sort_keys=True).encode(
                    "utf-8"
                )
                self.send_payload("application/json; charset=utf-8", payload)
                return
            if path == "/api/events":
                self.stream_events()
                return
            self.send_error(404, "Not found")

        def stream_events(self) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.end_headers()

            while True:
                payload = json.dumps(load_status(repo, status_path, queue_glob), sort_keys=True)
                try:
                    self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    return
                time.sleep(POLL_INTERVAL_MS / 1000)

        def send_payload(self, content_type: str, payload: bytes) -> None:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Pragma", "no-cache")
            self.send_header("Expires", "0")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format: str, *args: Any) -> None:
            sys.stderr.write("%s - %s\n" % (self.log_date_time_string(), format % args))

    return DashboardHandler


def main() -> int:
    parser = argparse.ArgumentParser(description="Serve the Agile Loop status dashboard.")
    parser.add_argument("--repo", default=".", help="Repository whose loop status should be shown.")
    parser.add_argument(
        "--status-file",
        default=".agile-loop/status.json",
        help="Status JSON path. Relative paths are resolved under --repo.",
    )
    parser.add_argument(
        "--queue-glob",
        default="docs/agile-loop/tasks/*.md",
        help="Task queue glob. Relative paths are resolved under --repo.",
    )
    parser.add_argument("--host", default="127.0.0.1", help="Bind host.")
    parser.add_argument("--port", type=int, default=8765, help="Bind port. Use 0 for an available port.")
    parser.add_argument("--open", action="store_true", help="Open the dashboard URL in the default browser.")
    args = parser.parse_args()

    repo = Path(args.repo).resolve()
    if not repo.exists():
        parser.error(f"repo does not exist: {repo}")

    status_path = resolve_status_path(repo, args.status_file)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(repo, status_path, args.queue_glob))
    url = f"http://{args.host}:{server.server_port}"
    print(f"Agile Loop dashboard: {url}", flush=True)
    print(f"Status file: {status_path}", flush=True)

    if args.open:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Agile Loop dashboard.", file=sys.stderr)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
