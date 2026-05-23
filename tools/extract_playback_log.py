#!/usr/bin/env python3
import argparse
import csv
import json
import re
import sys
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Iterable, List, Optional


LINE_RE = re.compile(
    r"^(?P<ts>[A-Z][a-z]{2}\s+\d+\s+\d\d:\d\d:\d\d)\s+"
    r"(?P<host>\S+)\s+(?P<level>\S+)\s+(?P<src>[^:]+):\s+(?P<msg>.*)$"
)
PLAYBACK_RE = re.compile(r"\[PLAYBACK\]\s+(?P<event>\S+)\s*(?P<details>.*)$")
PLAYER_RE = re.compile(r"\[PLAYER\]\s+(?P<msg>.*)$")


@dataclass
class Event:
    ts: str
    source: str
    kind: str
    message: str
    details: Optional[dict] = None


def parse_line(line: str) -> Optional[Event]:
    m = LINE_RE.match(line.rstrip("\n"))
    if not m:
        return None

    ts = m.group("ts")
    msg = m.group("msg")

    m_pb = PLAYBACK_RE.search(msg)
    if m_pb:
        raw = m_pb.group("details").strip()
        details = None
        if raw:
            try:
                details = json.loads(raw)
            except Exception:
                details = {"raw": raw}
        return Event(
            ts=ts,
            source="playback",
            kind=m_pb.group("event"),
            message=raw or "-",
            details=details,
        )

    m_player = PLAYER_RE.search(msg)
    if m_player:
        text = m_player.group("msg")
        return Event(ts=ts, source="player", kind="player_log", message=text, details=None)

    lowered = msg.lower()
    if "loading root/idle.mp3" in lowered:
        return Event(ts=ts, source="audio", kind="idle_start", message=msg)
    if "audio backend unavailable" in lowered:
        return Event(ts=ts, source="audio", kind="backend_unavailable", message=msg)
    if "audio disabled" in lowered:
        return Event(ts=ts, source="audio", kind="audio_disabled", message=msg)
    if "streamtitle:" in lowered:
        return Event(ts=ts, source="stream", kind="metadata", message=msg)
    return None


def read_events(lines: Iterable[str]) -> List[Event]:
    events = []
    for line in lines:
        ev = parse_line(line)
        if ev:
            events.append(ev)
    return events


def _parse_ts(ts: str) -> Optional[datetime]:
    try:
        parts = ts.split()
        if len(parts) != 3:
            return None
        mon_map = {
            "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
            "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
        }
        month = mon_map.get(parts[0])
        if not month:
            return None
        day = int(parts[1])
        hh, mm, ss = [int(x) for x in parts[2].split(":")]
        return datetime(2000, month, day, hh, mm, ss)
    except Exception:
        return None


def analysis(events: List[Event]) -> dict:
    if not events:
        return {
            "duration_sec": 0.0,
            "fallback_count": 0,
            "stream_started_count": 0,
            "source_changed_count": 0,
            "fallback_per_min": 0.0,
            "source_changes_per_min": 0.0,
            "cycles": 0,
            "likely_flapping": False,
        }

    first_dt = _parse_ts(events[0].ts)
    last_dt = _parse_ts(events[-1].ts)
    duration_sec = 0.0
    if first_dt and last_dt:
        duration_sec = max((last_dt - first_dt).total_seconds(), 1.0)
    else:
        duration_sec = float(max(len(events), 1))

    fallback_count = sum(1 for e in events if e.kind == "fallback_activated")
    stream_started_count = sum(1 for e in events if e.kind == "stream_started")
    source_changed_count = sum(1 for e in events if e.kind == "source_changed")
    cycles = min(fallback_count, stream_started_count)

    per_min_factor = 60.0 / duration_sec
    fallback_per_min = fallback_count * per_min_factor
    source_changes_per_min = source_changed_count * per_min_factor
    likely_flapping = fallback_per_min >= 1.0 and cycles >= 3

    return {
        "duration_sec": duration_sec,
        "fallback_count": fallback_count,
        "stream_started_count": stream_started_count,
        "source_changed_count": source_changed_count,
        "fallback_per_min": fallback_per_min,
        "source_changes_per_min": source_changes_per_min,
        "cycles": cycles,
        "likely_flapping": likely_flapping,
    }


def summarize(events: List[Event]) -> str:
    by_kind = Counter(e.kind for e in events)
    by_source = Counter(e.source for e in events)
    err_events = [e for e in events if "error" in e.kind or "unavailable" in e.kind or "disabled" in e.kind]
    idle_events = [e for e in events if e.kind == "idle_start"]
    playback_events = [e for e in events if e.source == "playback"]
    an = analysis(events)
    trigger_events = [e for e in events if e.kind == "fallback_check_triggered" and isinstance(e.details, dict)]
    broken_triggers = sum(1 for e in trigger_events if e.details.get("reason_broken"))
    silent_triggers = sum(1 for e in trigger_events if e.details.get("reason_silent"))

    lines = []
    lines.append("=== Playback Summary ===")
    lines.append(f"Total events: {len(events)}")
    lines.append(f"Playback events: {len(playback_events)}")
    lines.append(f"Idle starts: {len(idle_events)}")
    lines.append(f"Error-like events: {len(err_events)}")
    lines.append("")
    lines.append("Stability analysis:")
    lines.append(f"  - observed span: {an['duration_sec']:.1f}s")
    lines.append(f"  - fallback count: {an['fallback_count']}")
    lines.append(f"  - stream_started count: {an['stream_started_count']}")
    lines.append(f"  - source_changed count: {an['source_changed_count']}")
    lines.append(f"  - fallback/min: {an['fallback_per_min']:.2f}")
    lines.append(f"  - source_changes/min: {an['source_changes_per_min']:.2f}")
    lines.append(f"  - fallback->stream cycles: {an['cycles']}")
    lines.append(f"  - likely flapping: {'yes' if an['likely_flapping'] else 'no'}")
    if trigger_events:
        lines.append(f"  - fallback triggers analysed: {len(trigger_events)}")
        lines.append(f"    - broken-stream triggers: {broken_triggers}")
        lines.append(f"    - silent-stream triggers: {silent_triggers}")
    lines.append("")
    lines.append("By source:")
    for src, n in sorted(by_source.items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"  - {src}: {n}")
    lines.append("")
    lines.append("By kind:")
    for kind, n in sorted(by_kind.items(), key=lambda x: (-x[1], x[0])):
        lines.append(f"  - {kind}: {n}")
    if err_events:
        lines.append("")
        lines.append("Last error-like events:")
        for e in err_events[-5:]:
            lines.append(f"  - {e.ts} | {e.kind} | {e.message}")
    return "\n".join(lines)


def format_timeline(events: List[Event], newest_first: bool, limit: Optional[int]) -> str:
    seq = list(reversed(events)) if newest_first else events
    if limit:
        seq = seq[:limit]
    out = []
    for e in seq:
        if e.details:
            details_txt = json.dumps(e.details, ensure_ascii=False, separators=(",", ":"))
            out.append(f"{e.ts} | {e.kind:18} | {e.message} | {details_txt}")
        else:
            out.append(f"{e.ts} | {e.kind:18} | {e.message}")
    return "\n".join(out)


def write_csv(path: str, events: List[Event], newest_first: bool, limit: Optional[int]) -> None:
    seq = list(reversed(events)) if newest_first else events
    if limit:
        seq = seq[:limit]
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["ts", "source", "kind", "message", "details_json"])
        for e in seq:
            w.writerow([e.ts, e.source, e.kind, e.message, json.dumps(e.details, ensure_ascii=False) if e.details else ""])


def write_json(path: str, events: List[Event], newest_first: bool, limit: Optional[int]) -> None:
    seq = list(reversed(events)) if newest_first else events
    if limit:
        seq = seq[:limit]
    with open(path, "w", encoding="utf-8") as f:
        json.dump([asdict(e) for e in seq], f, ensure_ascii=False, indent=2)


def main() -> int:
    ap = argparse.ArgumentParser(description="Extract and format playback events from info-beamer device logs.")
    ap.add_argument("logfile", help="Path to exported device log file")
    ap.add_argument("--newest-first", action="store_true", help="Show newest events first")
    ap.add_argument("--limit", type=int, default=300, help="Output line limit (default: 300)")
    ap.add_argument("--summary", action="store_true", help="Print compact summary with flapping analysis")
    ap.add_argument("--csv", dest="csv_path", help="Optional CSV output path")
    ap.add_argument("--json", dest="json_path", help="Optional JSON output path")
    args = ap.parse_args()

    try:
        with open(args.logfile, "r", encoding="utf-8", errors="replace") as f:
            events = read_events(f)
    except FileNotFoundError:
        print(f"Log file not found: {args.logfile}", file=sys.stderr)
        return 2

    if not events:
        print("No playback-related events found.")
        return 0

    if args.summary:
        print(summarize(events))
        print("")

    print(format_timeline(events, newest_first=args.newest_first, limit=args.limit))

    if args.csv_path:
        write_csv(args.csv_path, events, newest_first=args.newest_first, limit=args.limit)
        print(f"\nWrote CSV: {args.csv_path}", file=sys.stderr)
    if args.json_path:
        write_json(args.json_path, events, newest_first=args.newest_first, limit=args.limit)
        print(f"Wrote JSON: {args.json_path}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
