#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="agile-loop"
REPO_OWNER="nirmitgoyal"
REPO_NAME="agile-loop"
REF="main"
HOST="auto"
SCOPE="user"
PROJECT_DIR="$(pwd)"
UPGRADE="0"
DRY_RUN="0"
SOURCE_DIR="${AGILE_LOOP_INSTALL_SOURCE:-}"
TMP_ROOT=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install Agile Loop into an agent skill directory.

Options:
  --host HOST       auto, all, codex, claude, antigravity. Defaults to auto.
  --scope SCOPE     user or project. Defaults to user.
  --project-dir DIR Project root for project-scoped installs. Defaults to cwd.
  --ref REF         Git ref to download when not installing from a local checkout. Defaults to main.
  --source DIR      Local Agile Loop checkout to install from.
  --upgrade         Replace an existing install.
  --dry-run         Print destinations without writing.
  -h, --help        Show this help.

Examples:
  curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash
  curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash -s -- --host claude
  curl -fsSL https://raw.githubusercontent.com/nirmitgoyal/agile-loop/main/scripts/install.sh | bash -s -- --host all --upgrade
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf "$TMP_ROOT"
  fi
}
trap cleanup EXIT

normalize_host() {
  case "$1" in
    auto|all|codex) printf '%s\n' "$1" ;;
    claude|claude-code|claudecode) printf '%s\n' "claude" ;;
    antigravity|anti-gravity|agy) printf '%s\n' "antigravity" ;;
    *) die "unknown host: $1" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="$(normalize_host "${2:-}")"; shift 2 ;;
    --scope) SCOPE="${2:-}"; shift 2 ;;
    --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --source) SOURCE_DIR="${2:-}"; shift 2 ;;
    --upgrade) UPGRADE="1"; shift ;;
    --dry-run) DRY_RUN="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ "$SCOPE" = "user" ] || [ "$SCOPE" = "project" ] || die "scope must be user or project"
[ -n "$REF" ] || die "--ref requires a value"

script_source_dir() {
  local script_path="${BASH_SOURCE[0]:-}"
  if [ -n "$script_path" ] && [ -f "$script_path" ]; then
    local script_dir
    script_dir="$(cd "$(dirname "$script_path")" && pwd -P)"
    if [ -f "$script_dir/../SKILL.md" ]; then
      cd "$script_dir/.." && pwd -P
      return 0
    fi
  fi
  return 1
}

download_source() {
  command -v curl >/dev/null 2>&1 || die "curl is required when installing without a local checkout"
  command -v tar >/dev/null 2>&1 || die "tar is required when installing without a local checkout"

  TMP_ROOT="$(mktemp -d)"
  local archive_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${REF}.tar.gz"
  local archive="$TMP_ROOT/source.tar.gz"
  curl -fsSL "$archive_url" -o "$archive"
  tar -xzf "$archive" -C "$TMP_ROOT"

  local unpacked
  unpacked="$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$unpacked" ] && [ -f "$unpacked/SKILL.md" ] || die "downloaded archive did not contain SKILL.md"
  printf '%s\n' "$unpacked"
}

resolve_source_dir() {
  if [ -n "$SOURCE_DIR" ]; then
    [ -f "$SOURCE_DIR/SKILL.md" ] || die "--source must point at an Agile Loop checkout containing SKILL.md"
    cd "$SOURCE_DIR" && pwd -P
    return 0
  fi
  if script_source_dir; then
    return 0
  fi
  download_source
}

same_dir() {
  local left="$1"
  local right="$2"
  [ -d "$left" ] && [ -d "$right" ] || return 1
  left="$(cd "$left" && pwd -P)"
  right="$(cd "$right" && pwd -P)"
  [ "$left" = "$right" ]
}

host_detected() {
  case "$1" in
    codex)
      command -v codex >/dev/null 2>&1 || [ -d "${CODEX_HOME:-$HOME/.codex}" ]
      ;;
    claude)
      command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]
      ;;
    antigravity)
      command -v antigravity >/dev/null 2>&1 || command -v agy >/dev/null 2>&1 || [ -d "$HOME/.gemini/antigravity" ]
      ;;
    *)
      return 1
      ;;
  esac
}

selected_hosts() {
  case "$HOST" in
    codex|claude|antigravity)
      printf '%s\n' "$HOST"
      ;;
    all)
      printf '%s\n%s\n%s\n' codex claude antigravity
      ;;
    auto)
      local found="0"
      for candidate in codex claude antigravity; do
        if host_detected "$candidate"; then
          printf '%s\n' "$candidate"
          found="1"
        fi
      done
      if [ "$found" = "0" ]; then
        cat >&2 <<'EOF'
No supported agent host was detected.
Re-run with one of:
  --host codex
  --host claude
  --host antigravity
  --host all
EOF
        exit 1
      fi
      ;;
  esac
}

dest_for() {
  local host="$1"
  case "$host:$SCOPE" in
    codex:user)
      printf '%s/skills/%s\n' "${CODEX_HOME:-$HOME/.codex}" "$SKILL_NAME"
      ;;
    codex:project)
      printf '%s/.codex/skills/%s\n' "$PROJECT_DIR" "$SKILL_NAME"
      ;;
    claude:user)
      printf '%s/.claude/skills/%s\n' "$HOME" "$SKILL_NAME"
      ;;
    claude:project)
      printf '%s/.claude/skills/%s\n' "$PROJECT_DIR" "$SKILL_NAME"
      ;;
    antigravity:user)
      printf '%s/.gemini/antigravity/skills/%s\n' "$HOME" "$SKILL_NAME"
      ;;
    antigravity:project)
      printf '%s/.agents/skills/%s\n' "$PROJECT_DIR" "$SKILL_NAME"
      ;;
    *)
      die "unsupported host/scope combination: $host/$SCOPE"
      ;;
  esac
}

copy_skill() {
  local source="$1"
  local dest="$2"
  local parent
  parent="$(dirname "$dest")"

  if [ "$DRY_RUN" = "1" ]; then
    printf 'Would install %s to %s\n' "$SKILL_NAME" "$dest"
    return 0
  fi

  if [ -e "$dest" ]; then
    [ "$UPGRADE" = "1" ] || die "$dest already exists; pass --upgrade to replace it"
    if same_dir "$source" "$dest"; then
      die "source and destination are the same ($dest); cannot upgrade in place"
    fi
    rm -rf "$dest"
  fi

  mkdir -p "$parent"
  mkdir -p "$dest"
  for item in SKILL.md README.md LICENSE agents docs references scripts tests; do
    if [ -e "$source/$item" ]; then
      cp -R "$source/$item" "$dest/"
    fi
  done
  printf 'Installed %s to %s\n' "$SKILL_NAME" "$dest"
}

main() {
  local source
  source="$(resolve_source_dir)"

  local installed="0"
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    copy_skill "$source" "$(dest_for "$host")"
    installed="1"
  done <<EOF
$(selected_hosts)
EOF

  [ "$installed" = "1" ] || die "no hosts selected"
}

main
