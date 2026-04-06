#!/usr/bin/env bash
# engine/windsurf-tracker.sh
#
# Windsurf local tracker reader.
#
# Windsurf Enterprise writes snapshot files to:
#   ~/.codeium/windsurf/code_tracker/active/
#
# Directory layout:
#   active/
#     <project_name>_<hash>/        ← one dir per project instance
#       <timestamp>_<filename>      ← snapshot of AI-suggested content
#       <timestamp>_<filename>
#
# This module locates the correct snapshot file for a given filename
# within a given project, then exposes it for the attribution engine.
# It handles both VS Code and IntelliJ layouts, which differ slightly
# in how project directories are named.
#
# Public functions (prefixed wst_ for Windsurf Tracker):
#
#   wst_tracker_base           Print the base tracker directory path
#   wst_project_dirs <name>    Find all tracker dirs matching project name
#   wst_find_snapshot <proj_dirs> <filename>   Find best snapshot file
#   wst_snapshot_for_file <repo_root> <rel_path> <outfile>
#                              Full resolution: repo → snapshot file path

[[ -n "${_DFM_WST_LOADED:-}" ]] && return 0
_DFM_WST_LOADED=1

# ── Base tracker directory ────────────────────────────────────────────────────
# This is where Windsurf Enterprise writes its local tracker files.
# Consistent across VS Code and IntelliJ on macOS.
wst_tracker_base() {
  echo "${WINDSURF_TRACKER_DIR:-$HOME/.codeium/windsurf/code_tracker/active}"
}

# ── Find project tracker directories ─────────────────────────────────────────
# Windsurf names tracker directories as: <project_name>_<hash>
# The project name matches the repository directory name but may include
# path separators replaced with underscores (IntelliJ) or be truncated
# (VS Code on long paths).
#
# Strategy: search for directories whose name starts with the project name.
# Return all matches sorted by modification time (newest first) so the
# caller gets the most recently active project instance first.
#
# Usage: wst_project_dirs <project_name>
# Output: newline-separated list of matching directory paths
wst_project_dirs() {
  local project_name="$1"
  local base
  base=$(wst_tracker_base)

  [[ ! -d "$base" ]] && return 0

  # Search for directories starting with the project name.
  # The _* suffix allows for any hash suffix Windsurf appends.
  find "$base" -maxdepth 1 -type d \
    \( -name "${project_name}_*" -o -name "${project_name}" \) \
    2>/dev/null \
  | while IFS= read -r dir; do
      # Output with modification time prefix for sorting
      stat -f "%m %N" "$dir" 2>/dev/null \
        || stat -c "%Y %n" "$dir" 2>/dev/null \
        || echo "0 $dir"
    done \
  | sort -rn \
  | cut -d' ' -f2-
}

# ── Find snapshot file for a specific filename ────────────────────────────────
# Within the project tracker directories, find the snapshot file that
# corresponds to a specific source file.
#
# Windsurf names snapshot files as: <timestamp>_<basename>
# where basename is the filename without path (just the last component).
#
# We want the most recently modified snapshot for this filename, since
# the engineer may have worked on the file across multiple sessions.
#
# Usage: wst_find_snapshot <project_dirs_newline_separated> <filename_basename>
# Output: path to best snapshot file, or empty string if none found
wst_find_snapshot() {
  local project_dirs="$1"   # newline-separated list of dirs
  local basename="$2"       # just the filename, e.g. "PaymentService.java"

  [[ -z "$project_dirs" ]] && return 0

  local best_time=0
  local best_file=""

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ ! -d "$dir" ]] && continue

    # Find files in this tracker dir whose name ends with _<basename>
    while IFS= read -r candidate; do
      [[ -z "$candidate" ]] && continue
      [[ ! -f "$candidate" ]] && continue
      [[ ! -s "$candidate" ]] && continue   # skip empty files

      local mtime
      mtime=$(stat -f "%m" "$candidate" 2>/dev/null \
              || stat -c "%Y" "$candidate" 2>/dev/null \
              || echo 0)

      if [[ "$mtime" -gt "$best_time" ]]; then
        best_time=$mtime
        best_file="$candidate"
      fi
    done < <(find "$dir" -maxdepth 1 -type f -name "*_${basename}" 2>/dev/null)

  done <<< "$project_dirs"

  echo "$best_file"
}

# ── Full resolution: repo + relative path → snapshot file ────────────────────
# The main entry point for the pre-push hook.
# Given the repo root and a file's relative path, finds the Windsurf
# snapshot for that file and copies it to <outfile> for the engine to use.
#
# Usage:
#   wst_snapshot_for_file <repo_root> <rel_path> <outfile>
# Returns:
#   0 and writes content to <outfile> if snapshot found
#   1 if no snapshot found (outfile will be empty)
wst_snapshot_for_file() {
  local repo_root="$1"
  local rel_path="$2"
  local outfile="$3"

  # We need two identifiers:
  # 1. Project name — the repo directory name
  # 2. File basename — just the filename component
  local project_name
  project_name=$(basename "$repo_root")

  local file_basename
  file_basename=$(basename "$rel_path")

  # Find matching project tracker directories
  local project_dirs
  project_dirs=$(wst_project_dirs "$project_name")

  if [[ -z "$project_dirs" ]]; then
    # No tracker dirs found for this project — Windsurf may not have
    # been used on this repo, or the project name differs.
    # Try a broader search using just the file basename across all projects.
    project_dirs=$(find "$(wst_tracker_base)" -maxdepth 1 -type d 2>/dev/null \
                   | tail -n +2)  # exclude the base dir itself
  fi

  # Find the best snapshot for this specific file
  local snapshot
  snapshot=$(wst_find_snapshot "$project_dirs" "$file_basename")

  if [[ -z "$snapshot" ]] || [[ ! -s "$snapshot" ]]; then
    > "$outfile"   # ensure outfile exists but is empty
    return 1
  fi

  # Copy snapshot content to outfile for the engine
  cp "$snapshot" "$outfile"
  return 0
}

# ── Diagnostic: list all tracker files for a project ─────────────────────────
# Useful for debugging when attribution is not working as expected.
# Usage: wst_list_tracked_files <repo_root>
wst_list_tracked_files() {
  local repo_root="$1"
  local project_name
  project_name=$(basename "$repo_root")

  local project_dirs
  project_dirs=$(wst_project_dirs "$project_name")

  if [[ -z "$project_dirs" ]]; then
    echo "No tracker directories found for project: $project_name"
    return
  fi

  echo "Windsurf tracker files for: $project_name"
  echo "Base: $(wst_tracker_base)"
  echo ""

  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    echo "  $dir/"
    find "$dir" -maxdepth 1 -type f 2>/dev/null \
    | while IFS= read -r f; do
        local size mtime
        size=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
        mtime=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f" 2>/dev/null \
                || stat -c "%y" "$f" 2>/dev/null | cut -c1-16 \
                || echo "unknown")
        echo "    $mtime  ${size} lines  $(basename "$f")"
      done
  done <<< "$project_dirs"
}
