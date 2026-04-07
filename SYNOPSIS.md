# DevFlow Metrics — Pilot Synopsis

## The problem we are trying to solve

Capital One has invested in AI coding tools — Claude Code and Windsurf —
and we want to understand the return on that investment. The existing tracking
system (Flight Attendant) currently covers GitHub Copilot but does not yet
accurately capture Claude Code or Windsurf usage. More importantly, the way
most AI metrics tools work tends to overcount AI contribution: if Claude was
open during a session, the whole commit gets flagged as AI-assisted, even if
you only asked Claude a question and wrote all the code yourself.

We want to measure something more honest: of the lines that actually ended up
in a commit, how many did the AI tool genuinely write?

---

## What we are building

A small set of lightweight scripts that run silently as git hooks on your
machine. They capture two things:

What AI wrote, at the moment it wrote it.
When Claude Code writes or edits a file, the script saves a snapshot of exactly
what Claude produced. When Windsurf is used, its own local tracker files serve
the same purpose.

What actually landed in git.
When you commit, the script compares the AI snapshot against the git diff using
an algorithm called multiset intersection. It counts only the lines that appear
in both — meaning lines Claude wrote that you kept. If you rewrote Claude's
code, Claude gets no credit. If you accepted it unchanged, Claude gets full credit.

The result is a per-file, per-commit record of AI versus human contribution
stored in a plain JSON file on your machine.

---

## What we are NOT doing

We are not sending your code anywhere.
Snapshots and data stay on your local machine or in our shared private repository.

We are not tracking individual performance.
The data is for understanding tool effectiveness at the team level, not for
evaluating individuals. Reports default to team-level aggregation.

We are not building a new platform.
The end goal is to bring verified attribution data into Flight Attendant using
their existing Kafka pipeline. We are building the evidence first.

---

## What it asks of you

Install it once.
Running setup.sh takes about five minutes. After that the hooks run silently
in the background as part of your normal git workflow. You will not notice them.

Commit your data weekly to a shared repo.
One git add and git commit per week to pool our data.

Flag anything that looks wrong.
If the attribution numbers feel off for a file you remember working on,
let us know. Catching inaccuracies early is part of the pilot.

That is it. No change to how you write code, use Claude, or use Windsurf.

---

## What the data looks like

Here is an example of what the weekly report shows after a few weeks of use:

    DevFlow Metrics -- By Tool

    your.email@capitalone.com
    Tool               AI lines       %   Events   Verified
    Claude Code           1,247   34.2%       31         28
    Windsurf                683   18.7%       19         17
    Human                   --    47.1%       44          --
    Total lines:          3,647

This is the report we do not have today. It shows Claude and Windsurf
separately, with a quality indicator (verified means the snapshot algorithm
was used, not just a commit-level guess).

---

## How it connects to Flight Attendant

Flight Attendant already has a Kafka pipeline and QuickSight dashboards.
Our pilot data uses the same event schema we would use to feed that pipeline.
Once the pilot demonstrates the approach works, the integration step is
replacing the local JSON file output with a Kafka publish. The dashboards
Flight Attendant already has would then show Claude and Windsurf data alongside
the Copilot data they already track.

We are not proposing a parallel system. We are proposing an extension.

---

## The timeline

Weeks 1 to 2.  Three engineers install and verify that data is being captured.
Weeks 3 to 4.  Normal development work with hooks running silently.
Week 4.        First combined report across the three of us.
Weeks 5 to 6.  Spot-check attribution accuracy, document any edge cases.
Week 6 onward. Present findings to the Flight Attendant team with working
               code, real data, and a concrete integration proposal.

---

## Requirements for participation

You need macOS, git, python3, and jq installed.
You need to be using Claude Code via CLI or Windsurf (IDE or plugin).
You need a Capital One SSO email address — this is the join key for attribution.
You need approximately five minutes to run the installer.

---

## Questions before you decide

What if I want to opt out partway through?
Removing the hooks takes thirty seconds. Your existing commits are not affected.

Does this capture anything sensitive?
The data contains file paths, line counts, timestamps, and your email. It does
not contain source code content. The temporary snapshot files that do contain
code stay on your local machine only.

What if the numbers look wrong?
That is exactly what we want to know. The health report flags low-confidence
events and we can investigate specific files together.

Who sees the data during the pilot?
The three engineers in the pilot group. Nobody else unless we decide together
to share it.

---

If you are interested, the next step is to run the installer in one of your
active repositories and let the hooks run for a week before we look at the
data together.
