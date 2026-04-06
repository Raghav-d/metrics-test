#!/usr/bin/env bash
# engine/runtime.sh
#
# Runtime utilities shared across all hooks and tools.
# Handles context resolution, identity, language detection, and safe I/O.
#
# Source this before any other devflow-metrics script:
#   source "$(dirname "$0")/../../engine/runtime.sh"

[[ -n "${_DFM_RUNTIME_LOADED:-}" ]] && return 0
_DFM_RUNTIME_LOADED=1

# ── Storage resolution ────────────────────────────────────────────────────────
# Where tracking data lives. Priority order:
#   1. DFM_DATA_DIR environment variable  (explicit override for shared pilot)
#   2. ~/.devflow/data                    (default, local to each machine)
#
# Set DFM_DATA_DIR in your shell profile to point at the shared pilot repo:
#   export DFM_DATA_DIR=/path/to/metrics-repo/data
dfm_data_dir() {
  echo "${DFM_DATA_DIR:-$HOME/.devflow/data}"
}

dfm_ledger_file() {
  echo "$(dfm_data_dir)/events.jsonl"
}

dfm_session_file() {
  echo "$(dfm_data_dir)/session_$(date +%Y%m%d).jsonl"
}

dfm_snapshot_dir() {
  echo "$(dfm_data_dir)/snapshots"
}

# ── Engineer identity ─────────────────────────────────────────────────────────
# Resolves the engineer's Your company SSO email address.
# This is the primary join key used across all downstream systems including
# Flight Attendant and any future Kafka pipeline.
#
# Resolution order:
#   1. DFM_ENGINEER_EMAIL environment variable  (set once, used everywhere)
#   2. git config user.email                    (standard git config)
#   3. ~/.devflow/engineer_email                (stored from setup.sh prompt)
#   4. "unknown"                                (fallback, triggers a warning)
#
# Engineers at Your company who authenticate via SSO may not have git config
# user.email set. setup.sh prompts for the email once and stores it at
# ~/.devflow/engineer_email so all subsequent hooks find it automatically.
dfm_engineer_email() {
  local email=""

  # Priority 1: explicit environment variable
  if [[ -n "${DFM_ENGINEER_EMAIL:-}" ]]; then
    echo "$DFM_ENGINEER_EMAIL"
    return
  fi

  # Priority 2: git config
  email=$(git config user.email 2>/dev/null || echo "")
  if [[ -n "$email" ]]; then
    echo "$email"
    return
  fi

  # Priority 3: stored from setup.sh prompt
  local stored="$HOME/.devflow/engineer_email"
  if [[ -f "$stored" ]]; then
    email=$(cat "$stored" | tr -d '[:space:]')
    if [[ -n "$email" ]]; then
      echo "$email"
      return
    fi
  fi

  # Priority 4: fallback
  dfm_warn "Engineer email not found. Run setup.sh to configure it."
  echo "unknown"
}

# ── Project context ───────────────────────────────────────────────────────────
dfm_repo_name() {
  local dir="${1:-$(pwd)}"
  local root
  root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  basename "$root"
}

dfm_repo_root() {
  local dir="${1:-$(pwd)}"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir"
}

dfm_active_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

dfm_short_sha() {
  git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# ── Timestamp ─────────────────────────────────────────────────────────────────
dfm_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ── Language detection ────────────────────────────────────────────────────────
dfm_detect_language() {
  local path="$1"
  local ext="${path##*.}"
  case "${ext,,}" in
    java)           echo "java" ;;
    kt|kts)         echo "kotlin" ;;
    py)             echo "python" ;;
    js)             echo "javascript" ;;
    ts)             echo "typescript" ;;
    jsx)            echo "jsx" ;;
    tsx)            echo "tsx" ;;
    go)             echo "go" ;;
    rb)             echo "ruby" ;;
    rs)             echo "rust" ;;
    cs)             echo "csharp" ;;
    cpp|cc|cxx|c)   echo "c_cpp" ;;
    sh|bash|zsh)    echo "shell" ;;
    tf|tfvars)      echo "terraform" ;;
    yaml|yml)       echo "yaml" ;;
    json)           echo "json" ;;
    xml)            echo "xml" ;;
    sql)            echo "sql" ;;
    md|markdown)    echo "markdown" ;;
    html|htm)       echo "html" ;;
    css|scss|sass)  echo "css" ;;
    swift)          echo "swift" ;;
    scala)          echo "scala" ;;
    r)              echo "r" ;;
    *)              echo "other" ;;
  esac
}

# ── File metrics ──────────────────────────────────────────────────────────────
dfm_line_count() {
  local path="$1"
  [[ -f "$path" ]] && wc -l < "$path" | tr -d ' ' || echo 0
}

# ── AI commit detection ───────────────────────────────────────────────────────
# Detects whether a commit was AI-assisted using known attribution signals:
#   - The Co-Authored-By: Claude Code trailer from managed-settings.json
#   - Author name or email containing anthropic/claude identifiers
# Returns "true" or "false".
dfm_is_ai_commit() {
  local sha="${1:-HEAD}"
  local author email body

  author=$(git log -1 --format='%an' "$sha" 2>/dev/null || echo "")
  email=$(git  log -1 --format='%ae' "$sha" 2>/dev/null || echo "")
  body=$(git   log -1 --format='%B'  "$sha" 2>/dev/null || echo "")

  if [[ "${author,,}" == *"claude"*    ]] || \
     [[ "${email,,}"  == *"anthropic"* ]] || \
     echo "$body" | grep -qi "co-authored-by: claude"; then
    echo "true"
  else
    echo "false"
  fi
}

# ── Safe append to JSONL ──────────────────────────────────────────────────────
# Validates JSON before writing and uses file locking to prevent
# corruption when multiple hooks run concurrently.
dfm_record_event() {
  local payload="$1"
  local ledger
  ledger=$(dfm_ledger_file)
  local session
  session=$(dfm_session_file)
  local lockfile="${ledger}.lock"

  mkdir -p "$(dirname "$ledger")"

  if ! echo "$payload" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    dfm_warn "Rejected invalid JSON — not written to ledger"
    return 1
  fi

  (
    flock -x 200 2>/dev/null || true
    echo "$payload" >> "$ledger"
    echo "$payload" >> "$session"
  ) 200>"$lockfile" 2>/dev/null \
  || {
    echo "$payload" >> "$ledger"
    echo "$payload" >> "$session"
  }
}

# ── Diagnostic output (stderr only) ──────────────────────────────────────────
# Hooks must never write to stdout — Claude Code reads hook stdout as
# structured JSON. All diagnostics go to stderr.
dfm_log()  { echo "[devflow] $1" >&2; }
dfm_warn() { echo "[devflow] WARN: $1" >&2; }

# ── Ledger query: Windsurf double-count guard ─────────────────────────────────
# Check whether a Windsurf attribution event already exists in the ledger
# for a given file + commit SHA. The post-commit hook calls this to avoid
# recording a duplicate when both the Windsurf pre-push hook and the
# post-commit hook run for the same push.
#
# Usage: dfm_windsurf_already_recorded <rel_path> <short_sha>
# Returns: "true" or "false"
dfm_windsurf_already_recorded() {
  local rel_path="$1"
  local short_sha="$2"
  local ledger
  ledger=$(dfm_ledger_file)

  [[ ! -f "$ledger" ]] && echo "false" && return

  if python3 -c "
import json, sys
found = False
with open('$(dfm_ledger_file)', 'r', errors='ignore') as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
            if (r.get('tool') == 'windsurf'
                    and r.get('file', {}).get('relative_path') == '$rel_path'
                    and r.get('project', {}).get('commit') == '$short_sha'):
                found = True
                break
        except Exception:
            continue
sys.exit(0 if found else 1)
" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}
