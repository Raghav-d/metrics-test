#!/usr/bin/env bash
# capture/windsurf/on-pre-push.sh
#
# Windsurf pre-push hook.
#
# Fires when the engineer runs git push, before the push completes.
# At this moment we know exactly what files are being pushed, and
# Windsurf has already written its local tracker files capturing
# what it suggested for each file.
#
# For each file in the push:
#   1. Read the Windsurf tracker snapshot for that file
#   2. Run the multiset intersection against the git diff
#   3. Write a ledger event with source "windsurf"
#
# Why pre-push (not post-commit) for Windsurf?
#   Windsurf's tracker files accumulate across a coding session.
#   At pre-push time we have the fullest picture of what Windsurf
#   suggested across all commits being pushed. Post-commit would
#   only see one commit at a time and might miss multi-commit sessions.
#
# Install path: .git/hooks/pre-push
#               (alongside or replacing any existing pre-push hook)
#
# Git calls pre-push with remote name and URL as arguments.
# It passes refs on stdin in format: <local-ref> <local-sha> <remote-ref> <remote-sha>
# We read these to know exactly which commits are being pushed.
#
# Always exits 0 — tracking failure must never block a push.

set -euo pipefail

# ── Locate engine ─────────────────────────────────────────────────────────────
_dfm_find_engine() {
  for candidate in \
    "$HOME/.devflow/engine" \
    "$HOME/devflow-metrics/engine"; do
    [[ -f "$candidate/runtime.sh" ]] && echo "$candidate" && return
  done
  echo ""
}

ENGINE_DIR=$(_dfm_find_engine)
[[ -z "$ENGINE_DIR" ]] && exit 0

source "$ENGINE_DIR/runtime.sh"
source "$ENGINE_DIR/compute.sh"
source "$ENGINE_DIR/windsurf-tracker.sh"

# ── Gather push context ───────────────────────────────────────────────────────
REPO_ROOT=$(dfm_repo_root)
REPO=$(dfm_repo_name)
BRANCH=$(dfm_active_branch)
EMAIL=$(dfm_engineer_email)
NOW=$(dfm_now)

# ── Read which refs git is pushing ───────────────────────────────────────────
# stdin format: <local-ref> <local-sha> <remote-ref> <remote-sha>
# We collect the local SHAs to determine which commits are new.
declare -a LOCAL_SHAS=()
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  # Skip deletions (sha of all zeros means branch deletion)
  [[ "$local_sha" =~ ^0+$ ]] && continue
  LOCAL_SHAS+=("$local_sha")
done

# Nothing being pushed
[[ ${#LOCAL_SHAS[@]} -eq 0 ]] && exit 0

# Determine upstream to diff against
UPSTREAM=$(dfm_best_ref)

# ── Collect all files in this push ────────────────────────────────────────────
# Get unique files changed across all commits being pushed
# that are not already on the remote (i.e. genuinely new in this push)
CHANGED_FILES=$(
  git diff --name-only "${UPSTREAM}..${LOCAL_SHAS[-1]}" 2>/dev/null \
  || git diff --name-only "HEAD~${#LOCAL_SHAS[@]}..HEAD" 2>/dev/null \
  || echo ""
)

[[ -z "$CHANGED_FILES" ]] && exit 0

# ── Temp workspace ────────────────────────────────────────────────────────────
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── Process each changed file ─────────────────────────────────────────────────
LOGGED=0
SKIPPED=0

while IFS= read -r REL_PATH; do
  [[ -z "$REL_PATH" ]] && continue

  FULL_PATH="$REPO_ROOT/$REL_PATH"
  LANGUAGE=$(dfm_detect_language "$REL_PATH")
  LINE_COUNT=$(dfm_line_count "$FULL_PATH")

  # Skip binary files
  if [[ -f "$FULL_PATH" ]] && \
     file --mime "$FULL_PATH" 2>/dev/null | grep -qv 'text/'; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # ── Find Windsurf snapshot for this file ─────────────────────────────────
  rm -f "$WORK/ws_snap.txt" "$WORK/ws_added.txt" "$WORK/ws_removed.txt"

  SNAPSHOT_FOUND=false
  if wst_snapshot_for_file "$REPO_ROOT" "$REL_PATH" "$WORK/ws_snap.txt"; then
    SNAPSHOT_FOUND=true
  fi

  # ── Run attribution ───────────────────────────────────────────────────────
  if [[ "$SNAPSHOT_FOUND" == "true" ]]; then
    CONTRIB_JSON=$(dfm_attribute \
                     "$WORK/ws_snap.txt" \
                     "$UPSTREAM" \
                     "$REL_PATH" \
                     "$WORK")
  else
    # No Windsurf snapshot found for this file.
    # This file was pushed but Windsurf did not track it — record as
    # unattributed rather than skipping, so the human side is complete.
    dfm_diff_added   "$UPSTREAM" "$REL_PATH" "$WORK/ws_added.txt"
    dfm_diff_removed "$UPSTREAM" "$REL_PATH" "$WORK/ws_removed.txt"

    NET_ADDED=$(wc -l < "$WORK/ws_added.txt"   2>/dev/null | tr -d ' ' || echo 0)
    NET_REMOVED=$(wc -l < "$WORK/ws_removed.txt" 2>/dev/null | tr -d ' ' || echo 0)

    CONTRIB_JSON=$(python3 - <<PYEOF
import json
print(json.dumps({
    "signal":      "marker_only",
    "quality":     "inferred",
    "ai_added":    0,
    "ai_removed":  0,
    "net_added":   $NET_ADDED,
    "net_removed": $NET_REMOVED
}))
PYEOF
)
    # Nothing attributed to Windsurf — skip recording this event.
    # The git post-commit hook will record the human side.
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # ── Emit ledger event ─────────────────────────────────────────────────────
  SHORT_SHA=$(dfm_short_sha)

  EVENT=$(python3 - <<PYEOF
import json

contrib = $CONTRIB_JSON

# Only record if Windsurf actually contributed lines
ai_added = contrib.get("ai_added", 0)
if ai_added == 0 and contrib.get("signal") == "snapshot_match":
    # Snapshot existed but nothing matched — engineer rewrote everything
    # Still worth recording as a verified zero-attribution event
    pass

event = {
    "version":     "1.0",
    "kind":        "ai_write",
    "captured_at": "$NOW",
    "tool":        "windsurf",
    "engineer": {
        "email":      "$EMAIL",
        "session_id": "$SHORT_SHA"
    },
    "project": {
        "repo":   "$REPO",
        "branch": "$BRANCH",
        "commit": "$SHORT_SHA"
    },
    "file": {
        "relative_path": "$REL_PATH",
        "language":      "$LANGUAGE",
        "line_count":    $LINE_COUNT
    },
    "contribution": contrib
}
print(json.dumps(event))
PYEOF
)

  dfm_record_event "$EVENT"
  LOGGED=$((LOGGED + 1))

  AI_ADDED=$(echo "$CONTRIB_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('ai_added',0))" 2>/dev/null || echo 0)
  SIGNAL=$(echo "$CONTRIB_JSON" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('signal','?'))" 2>/dev/null || echo "?")

  dfm_log "Windsurf: $REL_PATH  +${AI_ADDED} AI lines  [$SIGNAL]"

done <<< "$CHANGED_FILES"

dfm_log "Windsurf pre-push complete: $LOGGED file(s) attributed, $SKIPPED skipped"

# Always allow the push to proceed
exit 0
