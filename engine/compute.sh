#!/usr/bin/env bash
# engine/compute.sh
#
# The attribution engine.
#
# One job: given a snapshot of what an AI tool wrote and the actual
# lines that ended up in the git diff, compute how many of those
# committed lines came from AI.
#
# The algorithm is a multiset intersection. "Multiset" means we
# respect line counts, not just presence. Consider this case:
#
#   AI snapshot has 3 closing braces "}"
#   Git diff has    7 closing braces "}"
#   A naive set intersection would attribute all 7 to AI.
#   Multiset correctly attributes min(3,7) = 3 to AI.
#
# This prevents over-attribution of common lines like "}", "return;",
# blank lines, and other patterns that appear many times in code.
#
# Public API (functions prefixed with dfm_):
#
#   dfm_diff_added    <ref> <path> <outfile>   Extract added lines from diff
#   dfm_diff_removed  <ref> <path> <outfile>   Extract removed lines from diff
#   dfm_intersect     <snapshot> <diff_lines>  Compute attributed line count
#   dfm_attribute     <snapshot> <ref> <path> <tmpdir>   Full attribution JSON
#   dfm_best_ref                               Find best upstream git ref

[[ -n "${_DFM_ENGINE_LOADED:-}" ]] && return 0
_DFM_ENGINE_LOADED=1

# ── dfm_diff_added ────────────────────────────────────────────────────────────
# Extract the lines added to <path> between <ref> and HEAD.
# Writes one line per entry to <outfile>, no "+" prefix, no blank lines.
#
# Tries <ref>..HEAD first, then HEAD~1..HEAD as a fallback for the
# post-commit context where upstream may not be configured.
dfm_diff_added() {
  local ref="$1" path="$2" outfile="$3"

  # Primary: diff against upstream ref
  git diff "${ref}..HEAD" -- "$path" 2>/dev/null \
    | grep '^+' \
    | grep -v '^+++' \
    | sed 's/^+//' \
    > "$outfile" || true

  # Fallback: if nothing came out, try the previous commit
  if [[ ! -s "$outfile" ]]; then
    git diff 'HEAD~1..HEAD' -- "$path" 2>/dev/null \
      | grep '^+' \
      | grep -v '^+++' \
      | sed 's/^+//' \
      > "$outfile" || true
  fi
}

# ── dfm_diff_removed ──────────────────────────────────────────────────────────
# Same as dfm_diff_added but for removed lines.
dfm_diff_removed() {
  local ref="$1" path="$2" outfile="$3"

  git diff "${ref}..HEAD" -- "$path" 2>/dev/null \
    | grep '^-' \
    | grep -v '^---' \
    | sed 's/^-//' \
    > "$outfile" || true

  if [[ ! -s "$outfile" ]]; then
    git diff 'HEAD~1..HEAD' -- "$path" 2>/dev/null \
      | grep '^-' \
      | grep -v '^---' \
      | sed 's/^-//' \
      > "$outfile" || true
  fi
}

# ── dfm_clean_snapshot ────────────────────────────────────────────────────────
# Normalise a raw snapshot before comparison.
# Strips metadata lines that tools may inject (file:// paths, git hashes),
# and removes non-printable characters while preserving UTF-8 content.
dfm_clean_snapshot() {
  local raw="$1" out="$2"

  LC_ALL=C grep -v '^file://' "$raw" 2>/dev/null \
    | LC_ALL=C grep -v '^[0-9a-f]\{40\}$' \
    | LC_ALL=C tr -cd '\t\n\r\040-\176\200-\377' \
    > "$out" || true
}

# ── dfm_intersect ─────────────────────────────────────────────────────────────
# Compute the multiset intersection of <snapshot_file> and <diff_file>.
# Both files contain one line per entry (duplicates preserved).
# Returns the count of lines attributed to AI as an integer on stdout.
#
# For each unique line L:
#   attributed(L) = min( count_in_snapshot(L), count_in_diff(L) )
#
# Total attribution = sum of attributed(L) across all unique lines.
dfm_intersect() {
  local snapshot="$1" diff_lines="$2"

  # If either file is absent or empty, attribution is zero.
  [[ ! -s "$snapshot"   ]] && echo 0 && return
  [[ ! -s "$diff_lines" ]] && echo 0 && return

  awk '
    NR == FNR {
      # First file: snapshot — build frequency map
      freq_snap[$0]++
      next
    }
    {
      # Second file: diff lines — build frequency map
      freq_diff[$0]++
    }
    END {
      total = 0
      for (line in freq_diff) {
        if (line in freq_snap) {
          # Multiset min: how many of this line can we attribute to AI?
          total += (freq_diff[line] < freq_snap[line]) \
                     ? freq_diff[line] \
                     : freq_snap[line]
        }
      }
      print total
    }
  ' "$snapshot" "$diff_lines"
}

# ── dfm_attribute ─────────────────────────────────────────────────────────────
# Full attribution computation for one file.
#
# Arguments:
#   $1  snapshot_path   Path to raw snapshot file (empty string if none)
#   $2  upstream_ref    Git ref to diff against (e.g. "origin/main")
#   $3  rel_path        File path relative to repo root
#   $4  work_dir        Writable temp directory for intermediate files
#
# Output: a JSON object on stdout:
# {
#   "signal":    "snapshot_match" | "write_count" | "marker_only",
#   "quality":   "verified" | "inferred",
#   "ai_added":   <int>,
#   "ai_removed": <int>,
#   "net_added":  <int>,
#   "net_removed":<int>
# }
dfm_attribute() {
  local snapshot_path="$1"
  local upstream_ref="$2"
  local rel_path="$3"
  local work_dir="$4"

  local clean_snap="$work_dir/snap_clean.txt"
  local added_lines="$work_dir/diff_added.txt"
  local removed_lines="$work_dir/diff_removed.txt"

  # Step 1: extract the actual diff lines
  dfm_diff_added   "$upstream_ref" "$rel_path" "$added_lines"
  dfm_diff_removed "$upstream_ref" "$rel_path" "$removed_lines"

  local net_added=0 net_removed=0
  net_added=$(wc -l < "$added_lines"   2>/dev/null | tr -d ' ' || echo 0)
  net_removed=$(wc -l < "$removed_lines" 2>/dev/null | tr -d ' ' || echo 0)

  local ai_added=0 ai_removed=0
  local signal="marker_only"
  local quality="inferred"

  # Step 2: use snapshot if available
  if [[ -n "$snapshot_path" && -f "$snapshot_path" && -s "$snapshot_path" ]]; then

    dfm_clean_snapshot "$snapshot_path" "$clean_snap"

    if [[ -s "$clean_snap" ]]; then
      signal="snapshot_match"
      quality="verified"

      [[ "$net_added"   -gt 0 ]] && ai_added=$(dfm_intersect   "$clean_snap" "$added_lines")
      [[ "$net_removed" -gt 0 ]] && ai_removed=$(dfm_intersect "$clean_snap" "$removed_lines")
    fi

  elif [[ "$net_added" -gt 0 ]]; then
    # No snapshot — this was a full Write with no prior content.
    # Attribute all added lines to AI, but flag lower quality.
    signal="write_count"
    quality="inferred"
    ai_added=$net_added
  fi

  # Step 3: sanity bounds — AI attribution cannot exceed what changed
  [[ "$ai_added"   -gt "$net_added"   ]] && ai_added=$net_added
  [[ "$ai_removed" -gt "$net_removed" ]] && ai_removed=$net_removed

  # Step 4: emit JSON
  python3 - <<PYEOF
import json
print(json.dumps({
    "signal":      "$signal",
    "quality":     "$quality",
    "ai_added":    $ai_added,
    "ai_removed":  $ai_removed,
    "net_added":   $net_added,
    "net_removed": $net_removed
}))
PYEOF
}

# ── dfm_best_ref ──────────────────────────────────────────────────────────────
# Find the most appropriate git ref to diff against.
# Prefers the configured upstream tracking branch, falls back to common
# default branch names, then to the previous commit.
dfm_best_ref() {
  local upstream
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "")
  [[ -n "$upstream" ]] && echo "$upstream" && return

  for candidate in origin/main origin/master main master; do
    if git rev-parse --verify "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return
    fi
  done

  echo "HEAD~1"
}
