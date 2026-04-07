# DevFlow Metrics — Pilot README

## What this is

DevFlow Metrics is a small set of shell scripts and a Python reporting tool
that runs silently on your development machine. It tracks which lines of code
were written by AI tools (Claude Code and Windsurf) versus written by you,
and records that data in a local file that the three of us can pool and analyse
together.

The goal of this pilot is to answer a question that Capital One's existing
Flight Attendant system does not yet answer accurately: of the code we actually
commit, how much was genuinely written by AI, and how much did we write ourselves?

This is a four to six week pilot. You install it once, then forget about it.
At the end we look at the data together.

---

## Before you install

You need the following on your machine. Run each command to check:

    git --version
    python3 --version
    jq --version

If any of these is missing, install it with Homebrew:

    brew install git python3 jq

You also need to be inside a git repository when you run the installer.
The installer sets up hooks inside that repository's .git/hooks directory.
If you work across multiple repositories you can re-run the installer in
each one. The data all goes to the same place.

---

## Installation

Step 1. Download and unzip the devflow-metrics package to somewhere permanent
on your machine. A good location is your home directory:

    cd ~
    unzip devflow-metrics-v2.zip

This creates a folder called devflow-metrics. Do not delete this folder after
installing. The hooks reference it when they run.

Step 2. Navigate to the source code repository you want to track:

    cd ~/projects/your-repo-name

Step 3. Run the installer:

    ~/devflow-metrics/setup.sh

If the pilot team has agreed on a shared data directory (recommended), pass
it as an argument so your data goes to the shared location:

    ~/devflow-metrics/setup.sh --data-dir=~/pilot-metrics/data

Step 4. Follow the prompts. The installer will:

    - Check that your machine meets the requirements
    - Ask for your Capital One SSO email if it cannot find it automatically
    - Tell you clearly whether full mode or git-only mode is available
    - Install everything and show you a plain summary at the end

Step 5. Reload your shell so the environment variables take effect:

    source ~/.zshrc

That is the entire installation. You do not need to do anything else.

---

## Two modes of operation

The installer will tell you which mode it has installed. The mode depends on
whether Capital One's enterprise policy allows Claude Code hooks on your machine.

Full mode
    Both the Claude Code hook and the git hooks are active.
    Every time Claude Code writes or edits a file, the system captures a
    snapshot of exactly what Claude wrote. When you later commit that file,
    the system compares the snapshot against what actually went into git and
    counts only the lines that genuinely came from Claude. This is line-level
    attribution.

Git-only mode
    Only the git hooks are active. The system cannot capture snapshots of
    what Claude wrote in real time. Instead it uses the Co-Authored-By:
    Claude Code trailer that Capital One's managed settings already inject
    into AI-assisted commits. This gives you commit-level attribution rather
    than line-level. It is less precise but still useful data.

If you are in git-only mode and would like to request an upgrade to full mode,
the installer prints a suggested message you can send to the AI Tools team.

---

## What runs on your machine and when

Three hooks are installed. They run automatically as part of your normal
git workflow. You do not invoke them manually.

on-tool-result.sh
    Installed at:  ~/.claude/hooks/PostToolUse/on-tool-result.sh
    Runs when:     Claude Code finishes writing or editing a file (full mode only)
    What it does:  Saves a snapshot of what Claude wrote to a temporary file
                   on your machine. The snapshot stays local. It is used at
                   commit time to compute attribution and is never sent anywhere.

on-pre-push.sh
    Installed at:  .git/hooks/pre-push  (in your repo)
    Runs when:     You run git push
    What it does:  Reads Windsurf's local tracker files to find what Windsurf
                   suggested for each file you are pushing. Runs the attribution
                   algorithm and records the result. The push always proceeds
                   regardless of what this hook does.

post-commit
    Installed at:  .git/hooks/post-commit  (in your repo)
    Runs when:     You run git commit
    What it does:  For AI commits, loads the Claude snapshot and computes how
                   many of the committed lines came from Claude. For human
                   commits, records the lines you wrote yourself. This is the
                   complement signal that makes AI percentages meaningful.
                   Always exits successfully so it never blocks your commit.

All three hooks write diagnostic messages prefixed with [devflow] to your
terminal's error output. These are informational only. If you do not see them,
the hooks are still running — they just have nothing to report.

---

## Where your data goes

All data is stored locally on your machine at:

    ~/.devflow/data/events.jsonl         Main event ledger
    ~/.devflow/data/session_YYYYMMDD.jsonl   Daily session log
    ~/.devflow/data/snapshots/           Temporary AI snapshots (used at commit time)

The events.jsonl file is a plain text file. Each line is a JSON object
representing one file-level event. You can open it in any text editor.

If you installed with --data-dir pointing at a shared location, your data
goes there instead. The shared location is typically a private git repository
that the three pilot engineers commit to weekly.

Nothing is sent to any external system automatically. Your data stays on your
machine or in the shared pilot repository until the pilot team decides together
what to do with it.

---

## Checking your data

After you have made some commits run these commands to see what has been captured:

    python3 ~/.devflow/report/insight.py overview

This shows a high-level summary: total lines added, how many came from Claude,
how many from Windsurf, and how many you wrote yourself.

    python3 ~/.devflow/report/insight.py by-tool

This shows the Claude versus Windsurf versus human breakdown in a table.
This is the main report we will use when presenting to the Flight Attendant team.

    python3 ~/.devflow/report/insight.py health

This checks the data quality. Run this after your first few commits to
confirm attribution is working correctly. It will flag any issues such as
events where the snapshot was not found (which would lower attribution accuracy).

    python3 ~/.devflow/report/insight.py breakdown

Per-engineer breakdown. Useful once all three of us have data pooled.

    python3 ~/.devflow/report/insight.py timeline

Daily activity showing Claude, Windsurf, and human lines per day.

    python3 ~/.devflow/report/insight.py inspect src/YourFile.java

Full modification history for one specific file. Useful for spot-checking
that attribution looks right on a file you remember working on.

    python3 ~/.devflow/report/insight.py export output.csv

Exports everything to a CSV file you can open in Excel or share with the group.

---

## Understanding the attribution quality field

Every event in your data has a quality field with one of three values:

verified
    The system found a snapshot of what Claude wrote and compared it against
    what went into git. The line count is accurate. This is the best case.

inferred
    No snapshot was available. The system used the total lines added as an
    estimate of AI contribution. This happens when the Claude hook is not
    running (git-only mode) or when Windsurf was used but its tracker file
    was not found.

none
    This is a human commit. No AI attribution is attempted.

When you run the health report it shows you the percentage of AI events that
are verified versus inferred. If verified is below 50 percent it usually means
the Claude Code hook is not running. The health report will tell you what to
check.

---

## Sharing data with the pilot team

At the end of each week, commit your events.jsonl to the shared pilot repository:

    cd ~/pilot-metrics/data
    git add events.jsonl
    git commit -m "weekly sync - your.email@capitalone.com"
    git push

To analyse the combined data from all three engineers:

    DFM_DATA_DIR=~/pilot-metrics/data \
      python3 ~/.devflow/report/insight.py overview

    DFM_DATA_DIR=~/pilot-metrics/data \
      python3 ~/.devflow/report/insight.py by-tool

    DFM_DATA_DIR=~/pilot-metrics/data \
      python3 ~/.devflow/report/insight.py export pilot_combined.csv

---

## What the data does not contain

The data does not contain the actual source code you wrote or that Claude wrote.
It contains counts of lines, file paths, timestamps, your email address, and
metadata about which tool was involved. The temporary snapshot files in
~/.devflow/data/snapshots/ do contain code content but they stay on your local
machine and are used only by the attribution algorithm at commit time.

---

## Uninstalling

To remove the hooks from a repository:

    rm .git/hooks/post-commit
    rm .git/hooks/pre-push

To remove the Claude Code hook:

    rm ~/.claude/hooks/PostToolUse/on-tool-result.sh

To remove all DevFlow data and tools:

    rm -rf ~/.devflow

Your git history and commits are not affected by any of this.

---

## Troubleshooting

The hooks are not running after I commit.

    Check that the hooks are executable:
        ls -la .git/hooks/post-commit
        ls -la .git/hooks/pre-push

    If the permissions column does not show x, run:
        chmod +x .git/hooks/post-commit
        chmod +x .git/hooks/pre-push

The health report says verified is 0 percent.

    The Claude Code snapshot hook is probably not running. Check:
        ls ~/.claude/hooks/PostToolUse/on-tool-result.sh

    If the file is missing, re-run setup.sh.
    If the file exists, check whether allowManagedHooksOnly is blocking it:
        cat "/Library/Application Support/ClaudeCode/managed-settings.json" \
          | python3 -m json.tool | grep allowManagedHooks

I see [devflow] WARN: Engineer email not found in my terminal.

    Run setup.sh again. It will prompt you for your email and store it.
    Alternatively, add this line to your shell profile and reload it:
        export DFM_ENGINEER_EMAIL="your.email@capitalone.com"

The Windsurf pre-push hook says 0 files attributed.

    Windsurf's local tracker files may not have been populated yet for this
    repository. Use Windsurf in the repo, accept some suggestions, then push.
    You can also check whether the tracker files exist:
        ls ~/.codeium/windsurf/code_tracker/active/

---

## Questions

Bring any questions or unexpected results to the pilot group channel.
If attribution numbers look wrong for a specific file, run:

    python3 ~/.devflow/report/insight.py inspect path/to/that/file.java

and share the output. That will show the full event history for the file
and make it easy to identify where the discrepancy is.
