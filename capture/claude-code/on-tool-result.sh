#!/usr/bin/env bash
# capture/claude-code/on-tool-result.sh
#
# Claude Code PostToolUse hook.
#
# Fires immediately after Claude writes or edits a file, before the engineer
# has touched anything. This timing is critical: we capture exactly what the
# AI produced. Any engineer edits happen after this point.
#
# Claude Code delivers a JSON payload on stdin containing the tool name,
# file path, and content written. We extract and store:
#   1. A snapshot of what Claude wrote (for the attribution engine later)
#   2. A ledger event recording this AI activity
#
# The snapshot is the raw material for the multiset intersection algorithm.
# It lives on disk until the next git commit, when the engine reads it
# and compares it against what actually landed in the diff.
#
# Install path: ~/.claude/hooks/PostToolUse/on-tool-result.sh
#
# Exit behaviour: always exits 0. A tracking failure must never interrupt
# the engineer's Claude session.

set -euo pipefail

# ── Locate engine ─────────────────────────────────────────────────────────────
# Support multiple install locations so the hook works whether the pilot
# kit is installed system-wide or per-user.
_dfm_find_engine() {
  for candidate in \
    "$HOME/.devflow/engine" \
    "$HOME/devflow-metrics/engine" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../engine"; do
    [[ -f "$candidate/runtime.sh" ]] && echo "$candidate" && return
  done
  echo ""
}

ENGINE_DIR=$(_dfm_find_engine)

if [[ -z "$ENGINE_DIR" ]]; then
  # Engine not found — exit silently so Claude is never blocked
  exit 0
fi

source "$ENGINE_DIR/runtime.sh"

# ── Read Claude's hook payload ────────────────────────────────────────────────
RAW_INPUT=$(cat)

# ── Parse tool metadata ───────────────────────────────────────────────────────
_parse() {
  python3 -c "
import sys, json
d = json.load(sys.stdin)
key = '$1'.split('.')
val = d
for k in key:
    val = val.get(k, {}) if isinstance(val, dict) else ''
print(val if val != {} else '')
" <<< "$RAW_INPUT" 2>/dev/null || echo ""
}

TOOL=$(_parse "tool_name")
SESSION=$(_parse "session_id")
CWD=$(_parse "cwd")
FILE_PATH=$(_parse "tool_input.file_path")

# ── Only handle file-writing tools ───────────────────────────────────────────
case "$TOOL" in
  Write|Edit|NotebookEdit) ;;
  *) exit 0 ;;
esac

[[ -z "$FILE_PATH" ]] && exit 0
[[ -z "$CWD"       ]] && CWD=$(pwd)

# ── Resolve absolute and relative paths ──────────────────────────────────────
[[ "$FILE_PATH" != /* ]] && FILE_PATH="$CWD/$FILE_PATH"

REPO_ROOT=$(dfm_repo_root "$CWD")
REL_PATH="${FILE_PATH#$REPO_ROOT/}"

# ── Prepare storage ───────────────────────────────────────────────────────────
SNAP_DIR=$(dfm_snapshot_dir)
mkdir -p "$SNAP_DIR"

# Snapshot key: session + escaped path → unique per file per session
# Using double-underscore as separator since it never appears in paths
ESCAPED=$(echo "$REL_PATH" | tr '/' '__' | tr -cd '[:alnum:]_.-')
SNAPSHOT="$SNAP_DIR/${SESSION}__${ESCAPED}.snap"

# ── Extract and store the AI-written content ──────────────────────────────────
AI_LINES=0
REMOVED_LINES=0
KIND=""

case "$TOOL" in

  Write)
    KIND="ai_write"
    # Claude is creating or overwriting a file.
    # The snapshot is the complete content Claude wrote.
    CONTENT=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('content', ''))
" <<< "$RAW_INPUT" 2>/dev/null || echo "")

    if [[ -n "$CONTENT" ]]; then
      echo "$CONTENT" > "$SNAPSHOT"
      AI_LINES=$(echo "$CONTENT" | wc -l | tr -d ' ')
    elif [[ -f "$FILE_PATH" ]]; then
      cp "$FILE_PATH" "$SNAPSHOT"
      AI_LINES=$(dfm_line_count "$FILE_PATH")
    fi
    ;;

  Edit)
    KIND="ai_edit"
    # Claude is replacing a specific block of text within an existing file.
    # The snapshot accumulates the new_string from each edit in this session —
    # multiple edits to the same file append to the same snapshot.
    NEW_CONTENT=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('new_string', ''))
" <<< "$RAW_INPUT" 2>/dev/null || echo "")

    OLD_CONTENT=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('old_string', ''))
" <<< "$RAW_INPUT" 2>/dev/null || echo "")

    # Append each edit to the snapshot — the engine intersects all of them
    echo "$NEW_CONTENT" >> "$SNAPSHOT"

    AI_LINES=$(echo "$NEW_CONTENT"   | wc -l | tr -d ' ')
    REMOVED_LINES=$(echo "$OLD_CONTENT" | wc -l | tr -d ' ')
    ;;

  NotebookEdit)
    KIND="ai_edit"
    CELL_CONTENT=$(python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('new_source', ''))
" <<< "$RAW_INPUT" 2>/dev/null || echo "")

    echo "$CELL_CONTENT" >> "$SNAPSHOT"
    AI_LINES=$(echo "$CELL_CONTENT" | wc -l | tr -d ' ')
    ;;

esac

# ── Build and record the ledger event ────────────────────────────────────────
NOW=$(dfm_now)
REPO=$(dfm_repo_name "$CWD")
BRANCH=$(dfm_active_branch)
EMAIL=$(dfm_engineer_email)
LANGUAGE=$(dfm_detect_language "$REL_PATH")
LINE_COUNT=$(dfm_line_count "$FILE_PATH")

EVENT=$(python3 - <<PYEOF
import json
print(json.dumps({
    "version":      "1.0",
    "kind":         "$KIND",
    "captured_at":  "$NOW",
    "engineer": {
        "email":      "$EMAIL",
        "session_id": "$SESSION"
    },
    "project": {
        "repo":   "$REPO",
        "branch": "$BRANCH"
    },
    "file": {
        "relative_path": "$REL_PATH",
        "language":      "$LANGUAGE",
        "line_count":    $LINE_COUNT
    },
    "contribution": {
        "signal":      "snapshot_match",
        "quality":     "verified",
        "ai_added":    $AI_LINES,
        "ai_removed":  $REMOVED_LINES,
        "net_added":   $AI_LINES,
        "net_removed": $REMOVED_LINES
    },
    "snapshot_path": "$SNAPSHOT"
}))
PYEOF
)

dfm_record_event "$EVENT"
dfm_log "$TOOL captured: $REL_PATH (+${AI_LINES} lines)"

exit 0
