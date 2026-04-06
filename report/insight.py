#!/usr/bin/env python3
"""
report/insight.py

DevFlow Metrics reporting tool.
Reads the event ledger and answers the questions that matter for the pilot.

Usage:
    python3 insight.py overview
    python3 insight.py breakdown
    python3 insight.py by-tool
    python3 insight.py files [--top=N]
    python3 insight.py timeline
    python3 insight.py inspect <file-path>
    python3 insight.py health
    python3 insight.py export <output.csv>
"""

from __future__ import annotations

import csv
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


# ── Ledger location ───────────────────────────────────────────────────────────

def ledger_path() -> Path:
    data_dir = os.environ.get("DFM_DATA_DIR", str(Path.home() / ".devflow" / "data"))
    return Path(data_dir) / "events.jsonl"


# ── Loading ───────────────────────────────────────────────────────────────────

def load_events() -> list[dict[str, Any]]:
    path = ledger_path()
    if not path.exists():
        print(f"No data found at {path}", file=sys.stderr)
        print("Install the hooks and make some commits first.", file=sys.stderr)
        return []

    events: list[dict] = []
    bad = 0
    with open(path) as f:
        for i, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1

    if bad:
        print(f"Warning: skipped {bad} malformed records", file=sys.stderr)

    return events


# ── Safe field accessors ──────────────────────────────────────────────────────

def contrib(e: dict, field: str, default: Any = 0) -> Any:
    return e.get("contribution", {}).get(field, default)

def fld(e: dict, field: str, default: str = "") -> Any:
    return e.get("file", {}).get(field, default)

def eng(e: dict, field: str, default: str = "") -> str:
    return str(e.get("engineer", {}).get(field, default))

def proj(e: dict, field: str, default: str = "") -> str:
    return str(e.get("project", {}).get(field, default))

def tool_of(e: dict) -> str:
    """Return the tool that produced this event."""
    return e.get("tool", "unknown")


# ── Partitions ────────────────────────────────────────────────────────────────

def ai_events(events: list[dict]) -> list[dict]:
    return [e for e in events if e.get("kind") in ("ai_write", "ai_edit")]

def human_events(events: list[dict]) -> list[dict]:
    return [e for e in events if e.get("kind") == "human_commit"]

def claude_events(events: list[dict]) -> list[dict]:
    return [e for e in events if tool_of(e) == "claude_code"]

def windsurf_events(events: list[dict]) -> list[dict]:
    return [e for e in events if tool_of(e) == "windsurf"]

def verified_events(events: list[dict]) -> list[dict]:
    return [e for e in ai_events(events) if contrib(e, "quality") == "verified"]


# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

def cmd_overview(events: list[dict]) -> None:
    if not events:
        print("No events recorded yet.")
        return

    ai  = ai_events(events)
    hum = human_events(events)
    cl  = claude_events(events)
    ws  = windsurf_events(events)

    total_ai_added  = sum(contrib(e, "ai_added")  for e in ai)
    total_net_added = sum(contrib(e, "net_added")  for e in events)
    cl_added        = sum(contrib(e, "ai_added")  for e in cl)
    ws_added        = sum(contrib(e, "ai_added")  for e in ws)

    ai_pct  = (total_ai_added / total_net_added * 100) if total_net_added > 0 else 0
    cl_pct  = (cl_added / total_net_added * 100)       if total_net_added > 0 else 0
    ws_pct  = (ws_added / total_net_added * 100)       if total_net_added > 0 else 0

    engineers  = sorted({eng(e, "email") for e in events if eng(e, "email")})
    repos      = sorted({proj(e, "repo") for e in events if proj(e, "repo")})
    timestamps = [e.get("captured_at", "") for e in events if e.get("captured_at")]
    date_range = f"{min(timestamps)[:10]} → {max(timestamps)[:10]}" if timestamps else "—"
    ver_pct    = (len(verified_events(events)) / len(ai) * 100) if ai else 0

    W = 65
    print("═" * W)
    print("  DevFlow Metrics — Overview")
    print("═" * W)
    print(f"  Period:       {date_range}")
    print(f"  Engineers:    {len(engineers)}")
    for e in engineers:
        print(f"                  {e}")
    print(f"  Repositories: {', '.join(repos) or '—'}")
    print()
    print(f"  ── Total Lines Added ─────────────────────────────────")
    print(f"  All changes:           {total_net_added:>8,}")
    print(f"  AI-attributed (total): {total_ai_added:>8,}  ({ai_pct:.1f}%)")
    print(f"    ↳ Claude Code:       {cl_added:>8,}  ({cl_pct:.1f}%)")
    print(f"    ↳ Windsurf:          {ws_added:>8,}  ({ws_pct:.1f}%)")
    print(f"  Human-written:         {total_net_added - total_ai_added:>8,}  ({100-ai_pct:.1f}%)")
    print()
    print(f"  ── Signal Quality ────────────────────────────────────")
    print(f"  AI events:             {len(ai):>8,}")
    print(f"  Verified (snapshot):   {len(verified_events(events)):>8,}  ({ver_pct:.1f}%)")
    print(f"  Human events:          {len(hum):>8,}")
    print()


def cmd_by_tool(events: list[dict]) -> None:
    """
    The key report for the Flight Attendant conversation.
    Shows Claude vs Windsurf vs Human side by side — something
    Flight Attendant cannot produce today.
    """
    if not events:
        print("No events recorded yet.")
        return

    # Aggregate per engineer per tool
    stats: dict[str, dict[str, dict]] = defaultdict(
        lambda: {
            "claude_code": {"ai_added": 0, "net_added": 0, "events": 0, "verified": 0},
            "windsurf":    {"ai_added": 0, "net_added": 0, "events": 0, "verified": 0},
            "human":       {"ai_added": 0, "net_added": 0, "events": 0, "verified": 0},
        }
    )

    for e in events:
        email = eng(e, "email") or "unknown"
        t     = tool_of(e)
        if t not in ("claude_code", "windsurf", "human"):
            t = "human"
        d = stats[email][t]
        d["ai_added"]  += contrib(e, "ai_added")
        d["net_added"] += contrib(e, "net_added")
        d["events"]    += 1
        if contrib(e, "quality") == "verified":
            d["verified"] += 1

    W = 72
    print("═" * W)
    print("  DevFlow Metrics — By Tool")
    print("  (This is what Flight Attendant cannot show today)")
    print("═" * W)
    print()

    for email in sorted(stats):
        d  = stats[email]
        cl = d["claude_code"]
        ws = d["windsurf"]
        hu = d["human"]

        total = cl["net_added"] + ws["net_added"] + hu["net_added"]
        cl_pct = (cl["ai_added"] / total * 100) if total > 0 else 0
        ws_pct = (ws["ai_added"] / total * 100) if total > 0 else 0
        hu_pct = ((hu["net_added"] + (cl["net_added"] - cl["ai_added"])
                   + (ws["net_added"] - ws["ai_added"])) / total * 100) if total > 0 else 0

        print(f"  {email}")
        print(f"  {'─' * 60}")
        print(f"  {'Tool':<18} {'AI lines':>10}  {'%':>6}  {'Events':>7}  {'Verified':>9}")
        print(f"  {'─'*18} {'─'*10}  {'─'*6}  {'─'*7}  {'─'*9}")
        print(f"  {'Claude Code':<18} {cl['ai_added']:>10,}  {cl_pct:>5.1f}%"
              f"  {cl['events']:>7}  {cl['verified']:>9}")
        print(f"  {'Windsurf':<18} {ws['ai_added']:>10,}  {ws_pct:>5.1f}%"
              f"  {ws['events']:>7}  {ws['verified']:>9}")
        print(f"  {'Human':<18} {'—':>10}   {hu_pct:>5.1f}%"
              f"  {hu['events']:>7}  {'—':>9}")
        print(f"  {'Total lines:':<18} {total:>10,}")
        print()


def cmd_breakdown(events: list[dict]) -> None:
    if not events:
        print("No events recorded yet.")
        return

    by_engineer: dict[str, dict] = defaultdict(lambda: {
        "ai_added": 0, "net_added": 0,
        "claude_added": 0, "windsurf_added": 0,
        "ai_events": 0, "human_events": 0,
        "repos": set(), "languages": set()
    })

    for e in events:
        email = eng(e, "email") or "unknown"
        d = by_engineer[email]
        d["repos"].add(proj(e, "repo"))
        lang = fld(e, "language")
        if lang and lang != "other":
            d["languages"].add(lang)

        if e.get("kind") in ("ai_write", "ai_edit"):
            ai = contrib(e, "ai_added")
            d["ai_added"]  += ai
            d["net_added"] += contrib(e, "net_added")
            d["ai_events"] += 1
            if tool_of(e) == "claude_code":
                d["claude_added"] += ai
            elif tool_of(e) == "windsurf":
                d["windsurf_added"] += ai
        else:
            d["net_added"]    += contrib(e, "net_added")
            d["human_events"] += 1

    W = 65
    print("═" * W)
    print("  DevFlow Metrics — Per-Engineer Breakdown")
    print("═" * W)
    print()

    for email, d in sorted(by_engineer.items()):
        total  = d["net_added"]
        ai_pct = (d["ai_added"] / total * 100) if total > 0 else 0
        langs  = ", ".join(sorted(d["languages"] - {"", "other"}))

        print(f"  {email}")
        print(f"    Total lines:        {total:>7,}")
        print(f"    AI total:           {d['ai_added']:>7,}  ({ai_pct:.1f}%)")
        print(f"      Claude Code:      {d['claude_added']:>7,}")
        print(f"      Windsurf:         {d['windsurf_added']:>7,}")
        print(f"    AI events:          {d['ai_events']:>7,}")
        print(f"    Human events:       {d['human_events']:>7,}")
        print(f"    Languages:          {langs or '—'}")
        print(f"    Repos:              {', '.join(sorted(d['repos']) - {''}) or '—'}")
        print()


def cmd_files(events: list[dict], top: int = 20) -> None:
    if not events:
        print("No events recorded yet.")
        return

    file_data: dict[str, dict] = defaultdict(lambda: {
        "claude_added": 0, "windsurf_added": 0,
        "ai_added": 0, "net_added": 0,
        "language": "other", "line_count": 0,
        "verified": 0, "total_events": 0
    })

    for e in events:
        path = fld(e, "relative_path")
        if not path:
            continue
        d = file_data[path]
        d["language"]   = fld(e, "language") or d["language"]
        d["line_count"] = fld(e, "line_count") or d["line_count"]
        d["total_events"] += 1

        ai = contrib(e, "ai_added")
        d["ai_added"]  += ai
        d["net_added"] += contrib(e, "net_added")

        if tool_of(e) == "claude_code":
            d["claude_added"] += ai
        elif tool_of(e) == "windsurf":
            d["windsurf_added"] += ai
        if contrib(e, "quality") == "verified":
            d["verified"] += 1

    ranked = sorted(
        file_data.items(),
        key=lambda x: x[1]["ai_added"],
        reverse=True
    )[:top]

    W = 78
    print("═" * W)
    print(f"  DevFlow Metrics — Top {top} Files by AI Contribution")
    print("═" * W)
    print(f"  {'File':<42} {'Claude':>7}  {'Windsurf':>8}  {'AI %':>5}  {'Quality'}")
    print(f"  {'─'*42} {'─'*7}  {'─'*8}  {'─'*5}  {'─'*8}")

    for path, d in ranked:
        total  = d["net_added"]
        ai_pct = (d["ai_added"] / total * 100) if total > 0 else 0
        qual   = "verified" if d["verified"] > 0 else "inferred"
        short  = path if len(path) <= 40 else "…" + path[-39:]
        print(f"  {short:<42} {d['claude_added']:>7,}  {d['windsurf_added']:>8,}"
              f"  {ai_pct:>4.0f}%  {qual}")
    print()


def cmd_timeline(events: list[dict]) -> None:
    if not events:
        print("No events recorded yet.")
        return

    by_day: dict[str, dict] = defaultdict(
        lambda: {"claude": 0, "windsurf": 0, "human": 0}
    )

    for e in events:
        day = (e.get("captured_at") or "")[:10]
        if not day:
            continue
        t = tool_of(e)
        if t == "claude_code":
            by_day[day]["claude"]  += contrib(e, "ai_added")
        elif t == "windsurf":
            by_day[day]["windsurf"] += contrib(e, "ai_added")
        else:
            by_day[day]["human"]   += contrib(e, "net_added")

    W = 68
    print("═" * W)
    print("  DevFlow Metrics — Daily Timeline")
    print("═" * W)
    print(f"  {'Date':<12}  {'Claude':>8}  {'Windsurf':>9}  {'Human':>7}  {'AI %':>6}")
    print(f"  {'─'*12}  {'─'*8}  {'─'*9}  {'─'*7}  {'─'*6}")

    for day in sorted(by_day):
        cl    = by_day[day]["claude"]
        ws    = by_day[day]["windsurf"]
        hu    = by_day[day]["human"]
        total = cl + ws + hu
        pct   = ((cl + ws) / total * 100) if total > 0 else 0
        print(f"  {day:<12}  {cl:>8,}  {ws:>9,}  {hu:>7,}  {pct:>5.1f}%")
    print()


def cmd_inspect(events: list[dict], file_path: str) -> None:
    target = [e for e in events if fld(e, "relative_path") == file_path]
    if not target:
        print(f"No events found for: {file_path}")
        return

    target.sort(key=lambda e: e.get("captured_at", ""))

    W = 65
    print("═" * W)
    print(f"  History: {file_path}")
    print("═" * W)

    running: dict[str, int] = defaultdict(int)

    for e in target:
        ts      = (e.get("captured_at") or "")[:19]
        t       = tool_of(e)
        label   = {"claude_code": "Claude ", "windsurf": "Windsurf", "human": "Human  "}.get(t, t)
        email   = eng(e, "email")
        ai_add  = contrib(e, "ai_added")
        tot_add = contrib(e, "net_added")
        quality = contrib(e, "quality", "—")
        signal  = contrib(e, "signal", "—")

        running[t] += ai_add if t != "human" else tot_add

        print(f"  [{ts}]  {label}  {email}")
        print(f"    +{ai_add} AI / +{tot_add} total  |  {signal}  [{quality}]")
        print(f"    Running → Claude: {running['claude_code']}  "
              f"Windsurf: {running['windsurf']}  Human: {running['human']}")
        print()


def cmd_health(events: list[dict]) -> None:
    issues:   list[str] = []
    warnings: list[str] = []

    for i, e in enumerate(events, 1):
        ref = (f"Event {i} "
               f"({(e.get('captured_at') or '')[:10]} "
               f"{fld(e, 'relative_path')})")

        for req in ("version","kind","captured_at","engineer","project","file","contribution"):
            if req not in e:
                issues.append(f"{ref}: missing field '{req}'")

        if "tool" not in e:
            warnings.append(f"{ref}: missing 'tool' field — cannot distinguish Claude vs Windsurf")

        ai  = contrib(e, "ai_added")
        net = contrib(e, "net_added")
        if ai > net:
            issues.append(f"{ref}: ai_added ({ai}) > net_added ({net})")

        email = eng(e, "email")
        if email and "@" not in email:
            warnings.append(f"{ref}: email '{email}' looks invalid")

    cl_ct  = len(claude_events(events))
    ws_ct  = len(windsurf_events(events))
    ver_ct = len(verified_events(events))
    ai_ct  = len(ai_events(events))
    ver_pct = (ver_ct / ai_ct * 100) if ai_ct > 0 else 0

    print("═" * 62)
    print("  DevFlow Metrics — Data Health")
    print("═" * 62)
    print(f"  Total events:         {len(events):>6,}")
    print(f"  Claude Code events:   {cl_ct:>6,}")
    print(f"  Windsurf events:      {ws_ct:>6,}")
    print(f"  Verified (snapshot):  {ver_ct:>6,}  ({ver_pct:.1f}%)")
    print()

    if not issues and not warnings:
        print("  ✓  All events look healthy.")
    else:
        if issues:
            print(f"  ✗  {len(issues)} error(s):")
            for issue in issues:
                print(f"       {issue}")
        if warnings:
            print(f"  ⚠  {len(warnings)} warning(s):")
            for w in warnings:
                print(f"       {w}")

    if ws_ct == 0 and cl_ct > 0:
        print()
        print("  ℹ  No Windsurf events yet.")
        print("     Windsurf attribution is captured at git push time.")
        print("     Make sure on-pre-push.sh is installed as .git/hooks/pre-push")

    if ver_pct < 50 and ai_ct > 5:
        print()
        print("  ⚠  Under 50% of AI events are verified.")
        print("     Check that on-tool-result.sh is installed and hooks are enabled.")
    print()


def cmd_export(events: list[dict], output_path: str) -> None:
    if not events:
        print("No events to export.")
        return

    cols = [
        "captured_at", "kind", "tool", "email", "session_id",
        "repo", "branch", "commit",
        "relative_path", "language", "line_count",
        "ai_added", "ai_removed", "net_added", "net_removed",
        "signal", "quality"
    ]

    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=cols)
        writer.writeheader()
        for e in events:
            writer.writerow({
                "captured_at":   e.get("captured_at", ""),
                "kind":          e.get("kind", ""),
                "tool":          tool_of(e),
                "email":         eng(e, "email"),
                "session_id":    eng(e, "session_id"),
                "repo":          proj(e, "repo"),
                "branch":        proj(e, "branch"),
                "commit":        proj(e, "commit"),
                "relative_path": fld(e, "relative_path"),
                "language":      fld(e, "language"),
                "line_count":    fld(e, "line_count"),
                "ai_added":      contrib(e, "ai_added"),
                "ai_removed":    contrib(e, "ai_removed"),
                "net_added":     contrib(e, "net_added"),
                "net_removed":   contrib(e, "net_removed"),
                "signal":        contrib(e, "signal"),
                "quality":       contrib(e, "quality"),
            })

    print(f"Exported {len(events)} events → {output_path}")


def usage() -> None:
    print("""
DevFlow Metrics — Insight Tool

  python3 insight.py overview              High-level summary with tool split
  python3 insight.py by-tool               Claude vs Windsurf vs Human table
  python3 insight.py breakdown             Per-engineer contribution
  python3 insight.py files [--top=N]       Top files by AI lines (default 20)
  python3 insight.py timeline              Daily activity by tool
  python3 insight.py inspect <path>        Full history for one file
  python3 insight.py health                Data quality and coverage check
  python3 insight.py export <output.csv>   Export all events to CSV

Environment:
  DFM_DATA_DIR   Override default data directory (~/.devflow/data)
""")


def main() -> None:
    events = load_events()
    cmd    = sys.argv[1] if len(sys.argv) > 1 else "overview"
    args   = sys.argv[2:]

    dispatch = {
        "overview":  lambda: cmd_overview(events),
        "by-tool":   lambda: cmd_by_tool(events),
        "breakdown": lambda: cmd_breakdown(events),
        "timeline":  lambda: cmd_timeline(events),
        "health":    lambda: cmd_health(events),
    }

    if cmd in dispatch:
        dispatch[cmd]()
    elif cmd == "files":
        top = 20
        for a in args:
            if a.startswith("--top="):
                top = int(a.split("=", 1)[1])
        cmd_files(events, top)
    elif cmd == "inspect":
        if not args:
            print("Usage: insight.py inspect <file-path>")
            sys.exit(1)
        cmd_inspect(events, args[0])
    elif cmd == "export":
        if not args:
            print("Usage: insight.py export <output.csv>")
            sys.exit(1)
        cmd_export(events, args[0])
    else:
        print(f"Unknown command: {cmd}")
        usage()
        sys.exit(1)


if __name__ == "__main__":
    main()
