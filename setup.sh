#!/usr/bin/env bash
# setup.sh
# DevFlow Metrics Pilot -- Installer
#
# Run this once on each engineer's machine from the root of a source
# code repository you want to track. It checks your environment,
# resolves your SSO email, installs all hooks and tools, and tells
# you plainly what worked and what needs attention.
#
# Usage:
#   cd /path/to/your/source-repo
#   /path/to/devflow-metrics/setup.sh
#
# Options:
#   --data-dir=<path>   Where to store tracking data.
#                       Default: ~/.devflow/data
#                       For the shared pilot repo use:
#                         --data-dir=/path/to/metrics-repo/data

set -euo pipefail

PILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Plain output functions -- no colour codes, no special characters.
# Each line is prefixed with a short label so you can scan the output
# at a glance without needing a colour-capable terminal.
ok()   { echo "  OK      $1"; }
fail() { echo "  FAIL    $1"; }
note() { echo "  NOTE    $1"; }
warn() { echo "  WARN    $1"; }
step() { echo ""; echo "--- $1 ---"; }

# ── Parse arguments ───────────────────────────────────────────────────────────
DATA_DIR_ARG=""
for arg in "$@"; do
  case "$arg" in
    --data-dir=*) DATA_DIR_ARG="${arg#*=}" ;;
    --help|-h)
      echo "Usage: setup.sh [--data-dir=<path>]"
      echo ""
      echo "  --data-dir=<path>   Custom data directory."
      echo "                      Example: --data-dir=~/pilot-metrics/data"
      exit 0 ;;
  esac
done

# ── State tracking ────────────────────────────────────────────────────────────
CLAUDE_HOOKS_AVAILABLE=false
ABORT=false
declare -a STEPS_DONE
declare -a STEPS_WARN

echo ""
echo "DevFlow Metrics -- Pilot Installer"
echo "==================================="

# =============================================================================
step "Step 1 of 9 -- Environment checks"

# macOS check.
# uname returns "Darwin" on macOS. This installer is written for macOS only.
if [[ "$(uname)" == "Darwin" ]]; then
  ok "Running on macOS."
else
  fail "This installer requires macOS. Detected: $(uname)"
  ABORT=true
fi

# Required command-line tools.
MISSING=()
for dep in git python3 jq file; do
  if command -v "$dep" &>/dev/null; then
    ok "$dep is available."
  else
    MISSING+=("$dep")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  fail "Missing required tools: ${MISSING[*]}"
  fail "Install them with: brew install ${MISSING[*]}"
  ABORT=true
fi

# Git repository check.
if git rev-parse --git-dir &>/dev/null 2>&1; then
  REPO_ROOT=$(git rev-parse --show-toplevel)
  ok "Git repository found: $(basename "$REPO_ROOT")"
else
  fail "You are not inside a git repository."
  fail "Please cd into the source code repository you want to track, then re-run."
  ABORT=true
fi

if [[ "$ABORT" == "true" ]]; then
  echo ""
  fail "Setup cannot continue. Please fix the errors listed above and try again."
  exit 1
fi

# =============================================================================
step "Step 2 of 9 -- SSO email resolution"

# Engineers at - authenticate via SSO. git config user.email
# may or may not be set depending on the machine setup. We try several
# sources and, if none work, ask you to enter your email once. It is
# then stored at ~/.devflow/engineer_email and picked up automatically
# by every hook from that point on.

STORED_EMAIL_FILE="$HOME/.devflow/engineer_email"
RESOLVED_EMAIL=""

# Source 1: git config
RESOLVED_EMAIL=$(git config user.email 2>/dev/null || echo "")
if [[ -n "$RESOLVED_EMAIL" ]]; then
  note "Found email in git config: $RESOLVED_EMAIL"
fi

# Source 2: previously stored by this installer
if [[ -z "$RESOLVED_EMAIL" ]] && [[ -f "$STORED_EMAIL_FILE" ]]; then
  RESOLVED_EMAIL=$(cat "$STORED_EMAIL_FILE" | tr -d '[:space:]')
  if [[ -n "$RESOLVED_EMAIL" ]]; then
    note "Found stored email from previous setup: $RESOLVED_EMAIL"
  fi
fi

# Source 3: ask the engineer directly
if [[ -z "$RESOLVED_EMAIL" ]]; then
  echo ""
  echo "  Your Your Company SSO email address is used as the identity key"
  echo "  that connects your data to Flight Attendant and reporting dashboards."
  echo "  It is stored locally at ~/.devflow/engineer_email and never sent"
  echo "  anywhere automatically."
  echo ""
  printf "  Enter your Your Company SSO email address: "
  read -r RESOLVED_EMAIL
  RESOLVED_EMAIL=$(echo "$RESOLVED_EMAIL" | tr -d '[:space:]')
fi

# Validate format
if [[ -z "$RESOLVED_EMAIL" ]]; then
  fail "No email address provided. Setup cannot continue."
  exit 1
fi

if [[ "$RESOLVED_EMAIL" != *"@"* ]]; then
  warn "The email you entered does not look valid: $RESOLVED_EMAIL"
  warn "Attribution records will use this value as-is."
  STEPS_WARN+=("Email address may be invalid: $RESOLVED_EMAIL")
fi

if [[ "$RESOLVED_EMAIL" != *"@-.com" ]]; then
  warn "Email is not a @-.com address: $RESOLVED_EMAIL"
  warn "The SSO join key may not match Flight Attendant records."
  STEPS_WARN+=("Email is not @-.com -- SSO join key may not match")
else
  ok "SSO email confirmed: $RESOLVED_EMAIL"
fi

# Store the resolved email for all future hook invocations
mkdir -p "$(dirname "$STORED_EMAIL_FILE")"
echo "$RESOLVED_EMAIL" > "$STORED_EMAIL_FILE"
ok "Email stored at $STORED_EMAIL_FILE"

# Export for the current session
export DFM_ENGINEER_EMAIL="$RESOLVED_EMAIL"

# Also offer to set git config if it was not already set
EXISTING_GIT_EMAIL=$(git config user.email 2>/dev/null || echo "")
if [[ -z "$EXISTING_GIT_EMAIL" ]] && [[ -t 0 ]]; then
  echo ""
  printf "  Set this as your global git user.email too? (recommended) [Y/n]: "
  read -r SET_GIT_EMAIL
  if [[ "${SET_GIT_EMAIL:-Y}" =~ ^[Yy]$ ]]; then
    git config --global user.email "$RESOLVED_EMAIL"
    ok "Set git config --global user.email to $RESOLVED_EMAIL"
  else
    note "Skipped git config. The stored file will be used instead."
  fi
fi

# =============================================================================
step "Step 3 of 9 -- Claude Code hook availability"

# Your Company deploys a managed-settings.json that may block user-defined
# hooks via allowManagedHooksOnly: true. We check for this before attempting
# to install the Claude Code hook. If hooks are blocked we install in
# git-only mode, which still captures useful data using the Co-Authored-By
# trailer that managed-settings.json already injects into AI commits.

MANAGED="/Library/Application Support/ClaudeCode/managed-settings.json"

if [[ ! -f "$MANAGED" ]]; then
  ok "No managed-settings.json found. Claude Code hooks can be installed."
  CLAUDE_HOOKS_AVAILABLE=true
else
  HOOKS_ONLY=$(python3 -c "
import json
try:
    with open('$MANAGED') as fh:
        val = json.load(fh).get('allowManagedHooksOnly', False)
    print(str(val).lower())
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")

  if [[ "$HOOKS_ONLY" == "true" ]]; then
    warn "allowManagedHooksOnly is set to true in managed-settings.json."
    warn "The Claude Code hook (on-tool-result.sh) cannot be installed."
    echo ""
    echo "  What this means:"
    echo "  The hook that captures line-level snapshots of what Claude wrote"
    echo "  cannot run under the current enterprise policy. You will still get"
    echo "  commit-level AI vs human classification from the git post-commit hook,"
    echo "  but attribution will be at the commit level rather than the line level."
    echo ""
    echo "  To unlock full attribution for the pilot, ask your AI Tools team"
    echo "  for a temporary exemption on your machine. A suggested message:"
    echo "  'We are running a small internal pilot to validate AI metrics tooling"
    echo "   before proposing an org-wide rollout. We need hooks enabled on"
    echo "   three machines for approximately four to six weeks.'"
    echo ""
    echo "  Once exempted, re-run this installer: $0"
    echo ""
    STEPS_WARN+=("allowManagedHooksOnly is true -- running in git-only mode")
    CLAUDE_HOOKS_AVAILABLE=false
  else
    ok "allowManagedHooksOnly is not blocking hooks."
    CLAUDE_HOOKS_AVAILABLE=true
  fi
fi

# =============================================================================
step "Step 4 of 9 -- Data directory"

if [[ -n "$DATA_DIR_ARG" ]]; then
  DATA_DIR="$DATA_DIR_ARG"
  note "Using the data directory you specified: $DATA_DIR"
else
  DATA_DIR="$HOME/.devflow/data"
  note "Using the default data directory: $DATA_DIR"
  note "To use a shared pilot repo, re-run with: --data-dir=/path/to/shared/data"
fi

mkdir -p "$DATA_DIR" "$DATA_DIR/snapshots"
ok "Data directory is ready."
STEPS_DONE+=("Data directory: $DATA_DIR")

# =============================================================================
step "Step 5 of 9 -- Engine installation"

ENGINE_DEST="$HOME/.devflow/engine"
mkdir -p "$ENGINE_DEST"

cp "$PILOT_DIR/engine/runtime.sh"         "$ENGINE_DEST/"
cp "$PILOT_DIR/engine/compute.sh"         "$ENGINE_DEST/"
cp "$PILOT_DIR/engine/windsurf-tracker.sh" "$ENGINE_DEST/"
chmod +x "$ENGINE_DEST/runtime.sh" \
         "$ENGINE_DEST/compute.sh" \
         "$ENGINE_DEST/windsurf-tracker.sh"

ok "engine/runtime.sh installed."
ok "engine/compute.sh installed."
ok "engine/windsurf-tracker.sh installed."
STEPS_DONE+=("Engine installed to $ENGINE_DEST")

# =============================================================================
step "Step 6 of 9 -- Reporting tool"

REPORT_DEST="$HOME/.devflow/report"
mkdir -p "$REPORT_DEST"
cp "$PILOT_DIR/report/insight.py" "$REPORT_DEST/"
chmod +x "$REPORT_DEST/insight.py"
ok "report/insight.py installed."

if [[ -d "$HOME/bin" ]] && echo "$PATH" | grep -q "$HOME/bin"; then
  ln -sf "$REPORT_DEST/insight.py" "$HOME/bin/dfm"
  ok "Shortcut installed: dfm"
fi

STEPS_DONE+=("Reporting tool installed at $REPORT_DEST")

# =============================================================================
step "Step 7 of 9 -- Claude Code hook"

if [[ "$CLAUDE_HOOKS_AVAILABLE" == "true" ]]; then
  HOOK_DEST="$HOME/.claude/hooks/PostToolUse"
  mkdir -p "$HOOK_DEST"
  cp "$PILOT_DIR/capture/claude-code/on-tool-result.sh" "$HOOK_DEST/"
  chmod +x "$HOOK_DEST/on-tool-result.sh"
  ok "Claude Code PostToolUse hook installed to $HOOK_DEST"
  STEPS_DONE+=("Claude Code PostToolUse hook installed")
else
  warn "Skipped -- hooks are blocked by enterprise policy. See Step 3."
fi

# =============================================================================
step "Step 8 of 9 -- Git hooks"

GIT_HOOK_DIR="$REPO_ROOT/.git/hooks"

# post-commit hook
POST_COMMIT="$GIT_HOOK_DIR/post-commit"
if [[ -f "$POST_COMMIT" && ! -L "$POST_COMMIT" ]]; then
  cp "$POST_COMMIT" "${POST_COMMIT}.before-dfm"
  warn "Existing post-commit hook backed up to ${POST_COMMIT}.before-dfm"
fi
cp "$PILOT_DIR/capture/git/post-commit" "$POST_COMMIT"
chmod +x "$POST_COMMIT"
ok "Git post-commit hook installed in $(basename "$REPO_ROOT")"
STEPS_DONE+=("Git post-commit hook installed")

# pre-push hook (for Windsurf attribution)
PRE_PUSH="$GIT_HOOK_DIR/pre-push"
if [[ -f "$PRE_PUSH" && ! -L "$PRE_PUSH" ]]; then
  cp "$PRE_PUSH" "${PRE_PUSH}.before-dfm"
  warn "Existing pre-push hook backed up to ${PRE_PUSH}.before-dfm"
fi
cp "$PILOT_DIR/capture/windsurf/on-pre-push.sh" "$PRE_PUSH"
chmod +x "$PRE_PUSH"
ok "Windsurf pre-push hook installed in $(basename "$REPO_ROOT")"
STEPS_DONE+=("Windsurf pre-push hook installed")

# Windsurf tracker directory check
TRACKER_BASE="${WINDSURF_TRACKER_DIR:-$HOME/.codeium/windsurf/code_tracker/active}"
if [[ -d "$TRACKER_BASE" ]]; then
  FILE_COUNT=$(find "$TRACKER_BASE" -type f 2>/dev/null | wc -l | tr -d ' ')
  ok "Windsurf tracker directory found with $FILE_COUNT snapshot files."
else
  warn "Windsurf tracker directory not found at $TRACKER_BASE"
  warn "This is expected if you have not used Windsurf in this repo yet."
  warn "Windsurf attribution will start working once you use it here."
  STEPS_WARN+=("Windsurf tracker not yet populated")
fi

# =============================================================================
step "Step 9 of 9 -- Shell profile and verification"

# Detect shell profile
SHELL_PROFILE=""
for candidate in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  if [[ -f "$candidate" ]]; then
    SHELL_PROFILE="$candidate"
    break
  fi
done
SHELL_PROFILE="${SHELL_PROFILE:-$HOME/.zshrc}"

# Write DFM_DATA_DIR
if grep -q "DFM_DATA_DIR" "$SHELL_PROFILE" 2>/dev/null; then
  note "DFM_DATA_DIR is already set in $SHELL_PROFILE"
else
  {
    echo ""
    echo "# DevFlow Metrics Pilot"
    echo "export DFM_DATA_DIR=\"$DATA_DIR\""
    echo "export DFM_ENGINEER_EMAIL=\"$RESOLVED_EMAIL\""
  } >> "$SHELL_PROFILE"
  ok "Added DFM_DATA_DIR and DFM_ENGINEER_EMAIL to $SHELL_PROFILE"
  STEPS_DONE+=("Shell profile updated: $SHELL_PROFILE")
fi
export DFM_DATA_DIR="$DATA_DIR"

# Verify engine loads correctly
if bash -c "source '$ENGINE_DEST/runtime.sh' && dfm_now" &>/dev/null; then
  ok "Engine loads and runs correctly."
else
  fail "Engine failed to load. Check $ENGINE_DEST/runtime.sh"
fi

if python3 -c "import json, csv, sys, os, pathlib, collections" 2>/dev/null; then
  ok "Python standard library is available."
else
  fail "Python standard library check failed."
fi

if [[ -x "$POST_COMMIT" ]]; then
  ok "Git post-commit hook is executable."
else
  fail "Git post-commit hook is not executable."
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "==================================="
echo "Installation complete"
echo "==================================="
echo ""

if [[ "$CLAUDE_HOOKS_AVAILABLE" == "true" ]]; then
  echo "  Mode: Full"
  echo "  Both the Claude Code snapshot hook and the git hooks are active."
  echo "  Line-level AI attribution is enabled."
else
  echo "  Mode: Git-only"
  echo "  Only the git post-commit and pre-push hooks are active."
  echo "  You will get commit-level AI vs human classification."
  echo "  Request a hook exemption (see Step 3 above) for line-level attribution."
fi

echo ""
echo "  Engineer email: $RESOLVED_EMAIL"
echo "  Data directory: $DATA_DIR"
echo ""
echo "  Completed steps:"
for item in "${STEPS_DONE[@]}"; do
  echo "    - $item"
done

if [[ ${#STEPS_WARN[@]} -gt 0 ]]; then
  echo ""
  echo "  Items needing attention:"
  for item in "${STEPS_WARN[@]}"; do
    echo "    - $item"
  done
fi

echo ""
echo "  What to do next:"
echo ""
echo "  1. Reload your shell so the new environment variables take effect:"
echo "       source $SHELL_PROFILE"
echo ""
echo "  2. Work normally with Claude Code and Windsurf. The hooks run"
echo "     silently in the background. You will not notice them unless"
echo "     something goes wrong, in which case you will see a line"
echo "     beginning with [devflow] in your terminal output."
echo ""
echo "  3. After your first few commits and pushes, check your data:"
echo "       python3 $REPORT_DEST/insight.py overview"
echo "       python3 $REPORT_DEST/insight.py by-tool"
echo "       python3 $REPORT_DEST/insight.py health"
echo ""
echo "  4. To contribute your data to the shared pilot pool, commit"
echo "     your events.jsonl file weekly to the shared metrics repo:"
echo "       cd $DATA_DIR"
echo "       git add events.jsonl"
echo "       git commit -m \"weekly data sync -- $RESOLVED_EMAIL\""
echo "       git push"
echo ""
