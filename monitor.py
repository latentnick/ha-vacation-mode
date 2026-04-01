#!/usr/bin/env python3
"""
Monitor light switch activity from Home Assistant.

Queries the HA history API for the last 24 hours (or --hours N) and
renders a terminal timeline showing on/off state per light, plus a
recent-events log.

Usage:
    uv run monitor.py
    uv run monitor.py --hours 12
    uv run monitor.py --hours 48 --width 96

Reads HA_URL and HA_TOKEN from .env or environment.
Reads entity list from config.json.
"""

import os
import sys
import json
import argparse
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone, timedelta
from pathlib import Path


# ── Load .env ──────────────────────────────────────────────────────────────
# Check next to the script first, then the current working directory.
def _find_file(name: str) -> Path | None:
    for candidate in (Path(__file__).parent / name, Path.cwd() / name):
        if candidate.exists():
            return candidate
    return None

_env = _find_file(".env")
if _env:
    for line in _env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

HA_URL   = os.environ.get("HA_URL",   "http://homeassistant.local:8123")
HA_TOKEN = os.environ.get("HA_TOKEN", "")

if not HA_TOKEN:
    print("ERROR: HA_TOKEN environment variable is not set.")
    sys.exit(1)

# ── Load config ────────────────────────────────────────────────────────────
_config_path = _find_file("config.json")
if not _config_path:
    print("ERROR: config.json not found. Run configure.py first.")
    sys.exit(1)

HA_ENTITIES: list[str] = json.load(_config_path.open())["entities"]


# ── ANSI helpers ───────────────────────────────────────────────────────────
R   = "\033[0m"   # reset
B   = "\033[1m"   # bold
DIM = "\033[2m"
YEL = "\033[93m"  # yellow  — on
GRY = "\033[90m"  # gray    — off
CYN = "\033[96m"  # cyan    — headers

ON_CHAR  = "█"
OFF_CHAR = "░"


# ── HA API ─────────────────────────────────────────────────────────────────
def ha_get(path: str):
    req = urllib.request.Request(
        f"{HA_URL}{path}",
        headers={"Authorization": f"Bearer {HA_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


def fetch_history(entities: list[str], start: datetime, end: datetime) -> dict[str, list]:
    """
    Call /api/history/period/{start} and return {entity_id: [state_obj, ...]}.

    HA returns one sub-list per entity, each containing state objects with
    at least: entity_id, state, last_changed (ISO 8601 UTC string).
    The first object in each sub-list reflects the state at query start
    (a synthetic snapshot), so the full window is always covered.
    """
    start_str = start.strftime("%Y-%m-%dT%H:%M:%S+00:00")
    end_str   = end.strftime("%Y-%m-%dT%H:%M:%S+00:00")

    path = (
        f"/api/history/period/{urllib.parse.quote(start_str, safe='')}"
        f"?filter_entity_id={urllib.parse.quote(','.join(entities), safe='')}"
        f"&end_time={urllib.parse.quote(end_str, safe='')}"
    )

    raw = ha_get(path)

    result: dict[str, list] = {}
    for entity_states in raw:
        if entity_states:
            eid = entity_states[0]["entity_id"]
            result[eid] = entity_states
    return result


# ── Timeline rendering ─────────────────────────────────────────────────────
def _parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def _transitions(states: list[dict]) -> list[tuple[datetime, str]]:
    """Return sorted list of (timestamp, 'on'|'off') from HA state objects."""
    result = []
    for s in states:
        state = s["state"].lower()
        if state in ("on", "off"):
            result.append((_parse_ts(s["last_changed"]), state))
    result.sort(key=lambda x: x[0])
    return result


def _state_at(transitions: list[tuple[datetime, str]], t: datetime) -> str | None:
    """Return the on/off state at time t, or None if unknown."""
    current = None
    for ts, state in transitions:
        if ts <= t:
            current = state
        else:
            break
    return current


def build_timeline(states: list[dict], start: datetime, end: datetime, width: int) -> str:
    total_secs  = (end - start).total_seconds()
    secs_per_ch = total_secs / width
    txns = _transitions(states)

    chars = []
    for i in range(width):
        mid = start + timedelta(seconds=(i + 0.5) * secs_per_ch)
        s = _state_at(txns, mid)
        if s == "on":
            chars.append(f"{YEL}{ON_CHAR}{R}")
        elif s == "off":
            chars.append(f"{GRY}{OFF_CHAR}{R}")
        else:
            chars.append(f"{DIM} {R}")
    return "".join(chars)


def on_percentage(states: list[dict], start: datetime, end: datetime) -> float:
    """Compute percentage of the window during which the light was on."""
    txns = _transitions(states)
    if not txns:
        return 0.0

    on_secs = 0.0
    # Determine state at window start
    prev_state = _state_at(txns, start) or txns[0][1]
    prev_ts = start

    for ts, state in txns:
        if ts <= start:
            prev_state = state
            prev_ts = start
            continue
        if ts >= end:
            break
        if prev_state == "on":
            on_secs += (ts - prev_ts).total_seconds()
        prev_ts = ts
        prev_state = state

    # Final segment to end of window
    if prev_state == "on":
        on_secs += (end - prev_ts).total_seconds()

    total = (end - start).total_seconds()
    return (on_secs / total * 100) if total > 0 else 0.0


def friendly(entity_id: str) -> str:
    return entity_id.split(".", 1)[-1].replace("_", " ").title()


# ── Time axis ──────────────────────────────────────────────────────────────
def build_axis(start: datetime, end: datetime, width: int, prefix_width: int) -> str:
    """Return a two-line string: label row + tick row, with a blank prefix."""
    total_secs = (end - start).total_seconds()
    total_hours = total_secs / 3600

    tick_interval = 1 if total_hours <= 6 else 2 if total_hours <= 12 else 4 if total_hours <= 24 else 6

    ticks  = [" "] * width
    labels = [" "] * width

    def mark(t: datetime, label: str, tick_char: str = "┬"):
        pos = int((t - start).total_seconds() / total_secs * width)
        pos = max(0, min(width - 1, pos))
        ticks[pos] = tick_char
        lstart = pos - len(label) // 2
        for j, ch in enumerate(label):
            idx = lstart + j
            if 0 <= idx < width:
                labels[idx] = ch

    # Whole-hour ticks
    cur = start.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
    while cur < end:
        local = cur.astimezone()
        if int(local.strftime("%H")) % tick_interval == 0:
            mark(cur, local.strftime("%H:%M"))
        cur += timedelta(hours=1)

    # "now" marker at the right edge
    mark(end, "now", "┤")

    pad = " " * prefix_width
    return (
        f"{pad}{DIM}{''.join(labels)}{R}\n"
        f"{pad}{DIM}{''.join(ticks)}{R}"
    )


# ── Main render ────────────────────────────────────────────────────────────
def render(history: dict[str, list], entities: list[str],
           start: datetime, end: datetime, width: int):
    tz_name    = datetime.now().astimezone().strftime("%Z")
    start_disp = start.astimezone().strftime("%b %d %H:%M")
    end_disp   = end.astimezone().strftime("%b %d %H:%M")

    print()
    print(f"{B}{CYN}Light Activity Monitor{R}  "
          f"{DIM}{start_disp} – {end_disp} {tz_name}{R}")
    print()

    name_width = max((len(friendly(e)) for e in entities), default=10)
    # prefix = "  <name>  " before the bar
    prefix_width = name_width + 4

    print(build_axis(start, end, width, prefix_width))
    print()

    all_events: list[tuple[datetime, str, str]] = []

    for entity_id in entities:
        states = history.get(entity_id, [])
        name   = friendly(entity_id)

        timeline = build_timeline(states, start, end, width)
        pct      = on_percentage(states, start, end)

        # Current state
        cur_label = f"{DIM}---{R}"
        if states:
            cur = states[-1]["state"].lower()
            if cur == "on":
                cur_label = f"{YEL}{B}ON {R}"
            elif cur == "off":
                cur_label = f"{GRY}OFF{R}"

        print(f"  {B}{name.ljust(name_width)}{R}  {timeline}  {cur_label}  {pct:4.0f}%")

        for s in states:
            state = s["state"].lower()
            if state in ("on", "off"):
                all_events.append((_parse_ts(s["last_changed"]), entity_id, state))

    # ── Recent events ──────────────────────────────────────────────────────
    all_events.sort(key=lambda x: x[0], reverse=True)
    recent = all_events[:30]

    print()
    print(f"{B}{CYN}Recent events:{R}")
    print()

    if not recent:
        print(f"  {DIM}No events in window.{R}")
    else:
        for ts, eid, state in recent:
            ts_disp = ts.astimezone().strftime("%b %d %H:%M:%S")
            name    = friendly(eid)
            if state == "on":
                action = f"{YEL}▶ turn_on {R}"
            else:
                action = f"{GRY}■ turn_off{R}"
            print(f"  {DIM}{ts_disp}{R}  {action}  {name}")

    print()


# ── Entry point ────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Monitor HA light switch activity in the terminal.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--hours", type=float, default=24.0,
        help="how many hours back to show",
    )
    parser.add_argument(
        "--width", type=int, default=72,
        help="timeline bar width in characters",
    )
    args = parser.parse_args()

    end   = datetime.now(timezone.utc)
    start = end - timedelta(hours=args.hours)

    print(f"Fetching {args.hours:.0f}h of history from {HA_URL} …")

    try:
        history = fetch_history(HA_ENTITIES, start, end)
    except urllib.error.URLError as e:
        print(f"ERROR: Could not reach Home Assistant: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}")
        raise

    render(history, HA_ENTITIES, start, end, args.width)


if __name__ == "__main__":
    main()
