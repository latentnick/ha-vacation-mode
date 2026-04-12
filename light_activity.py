#!/usr/bin/env python3
"""
Generate a self-contained HTML report of light switch activity.

Queries the HA history API for the past 7 full days (excluding today)
and produces an HTML file with timeline visualizations per light per day.

Usage:
    uv run light_activity.py
    uv run light_activity.py --output report.html
    uv run light_activity.py --days 14

Reads HA_URL and HA_TOKEN from .env or environment.
Reads entity list from config.json.
"""

import os
import sys
import json
import html
import argparse
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


# ── Load .env ────────────────────────────────────────────────────────────────
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

# ── Load config ──────────────────────────────────────────────────────────────
_config_path = _find_file("config.json")
if not _config_path:
    print("ERROR: config.json not found. Run configure.py first.")
    sys.exit(1)

HA_ENTITIES: list[str] = json.load(_config_path.open())["entities"]

LOCAL_TZ = ZoneInfo("US/Pacific")


# ── HA API ───────────────────────────────────────────────────────────────────
def ha_get(path: str):
    req = urllib.request.Request(
        f"{HA_URL}{path}",
        headers={"Authorization": f"Bearer {HA_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
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


# ── Data processing ──────────────────────────────────────────────────────────
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


def on_segments_for_day(
    transitions: list[tuple[datetime, str]],
    day_start: datetime,
    day_end: datetime,
) -> list[tuple[float, float]]:
    """Return list of (start_pct, end_pct) for 'on' periods within a day."""
    total_secs = (day_end - day_start).total_seconds()
    if total_secs <= 0:
        return []

    # Find the state at day_start
    current = "off"
    for ts, state in transitions:
        if ts <= day_start:
            current = state
        else:
            break

    segments = []
    seg_start = 0.0 if current == "on" else None

    for ts, state in transitions:
        if ts <= day_start:
            continue
        if ts >= day_end:
            break
        pct = (ts - day_start).total_seconds() / total_secs * 100
        if state == "on" and seg_start is None:
            seg_start = pct
        elif state == "off" and seg_start is not None:
            segments.append((seg_start, pct))
            seg_start = None

    if seg_start is not None:
        segments.append((seg_start, 100.0))

    return segments


def friendly(entity_id: str) -> str:
    return entity_id.split(".", 1)[-1].replace("_", " ").title()


# ── Event log ────────────────────────────────────────────────────────────────
def collect_events(
    history: dict[str, list],
    entities: list[str],
    start: datetime,
    end: datetime,
) -> list[dict]:
    events = []
    for entity_id in entities:
        states = history.get(entity_id, [])
        for s in states:
            state = s["state"].lower()
            if state not in ("on", "off"):
                continue
            ts = _parse_ts(s["last_changed"])
            if ts < start or ts >= end:
                continue
            events.append({
                "time": ts,
                "entity": friendly(entity_id),
                "action": "turn_on" if state == "on" else "turn_off",
            })
    events.sort(key=lambda x: x["time"], reverse=True)
    return events


# ── HTML generation ──────────────────────────────────────────────────────────
def generate_html(
    history: dict[str, list],
    entities: list[str],
    days: list[tuple[datetime, datetime, str]],
) -> str:
    # Precompute data per entity
    entity_data = []
    for entity_id in entities:
        states = history.get(entity_id, [])
        txns = _transitions(states)
        name = friendly(entity_id)

        day_rows = []
        total_on = 0.0
        for day_start, day_end, label in days:
            segs = on_segments_for_day(txns, day_start, day_end)
            pct = sum(end - start for start, end in segs)
            total_on += pct
            day_rows.append({"label": label, "segments": segs, "pct": pct})

        avg_on = total_on / len(days) if days else 0
        entity_data.append({
            "name": name,
            "entity_id": entity_id,
            "days": day_rows,
            "avg_on": avg_on,
        })

    # Collect events
    if days:
        all_start = days[-1][0]
        all_end = days[0][1]
    else:
        all_start = all_end = datetime.now(timezone.utc)
    events = collect_events(history, entities, all_start, all_end)

    date_range_str = (
        f"{days[-1][0].astimezone(LOCAL_TZ).strftime('%b %-d')} &ndash; "
        f"{days[0][1].astimezone(LOCAL_TZ).strftime('%b %-d, %Y')}"
    ) if days else ""

    parts = [_html_head(date_range_str)]
    parts.append(_html_summary(len(entities), len(days), entity_data))
    parts.append(_html_timelines(entity_data))
    parts.append(_html_heatmap(entity_data, days))
    parts.append(_html_events(events[:100]))
    parts.append("</div></body></html>")
    return "\n".join(parts)


def _html_head(date_range: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Light Activity Report</title>
<style>
:root {{
  --bg: #0f1117;
  --surface: #1a1d27;
  --surface2: #242835;
  --border: #2e3345;
  --text: #e2e4eb;
  --text-dim: #8b8fa3;
  --accent: #f5c542;
  --on: #f5c542;
  --bar-bg: #1e2130;
  --green: #4ade80;
  --red: #f87171;
  --cyan: #67e8f9;
}}
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--bg);
  color: var(--text);
  line-height: 1.5;
  min-height: 100vh;
}}
.container {{
  max-width: 960px;
  margin: 0 auto;
  padding: 2rem 1.5rem;
}}
h1 {{
  font-size: 1.6rem;
  font-weight: 700;
  margin-bottom: 0.25rem;
}}
.date-range {{
  color: var(--text-dim);
  font-size: 0.95rem;
  margin-bottom: 2rem;
}}
h2 {{
  font-size: 1.15rem;
  font-weight: 600;
  margin-bottom: 0.5rem;
}}
.subtitle {{
  color: var(--text-dim);
  font-size: 0.85rem;
  margin-bottom: 1.25rem;
}}
.section {{
  margin-bottom: 2.5rem;
}}

/* Summary cards */
.summary-grid {{
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 1rem;
  margin-bottom: 2.5rem;
}}
.card {{
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1.1rem 1.25rem;
}}
.card-label {{
  font-size: 0.78rem;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 0.3rem;
}}
.card-value {{
  font-size: 1.5rem;
  font-weight: 700;
}}
.card-detail {{
  font-size: 0.82rem;
  color: var(--text-dim);
  margin-top: 0.2rem;
}}

/* Entity timeline cards */
.entity-card {{
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1.25rem;
  margin-bottom: 1rem;
}}
.entity-header {{
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin-bottom: 0.85rem;
}}
.entity-name {{
  font-weight: 600;
  font-size: 1rem;
}}
.entity-avg {{
  font-size: 0.82rem;
  color: var(--text-dim);
}}
.day-row {{
  display: flex;
  align-items: center;
  margin-bottom: 0.35rem;
  gap: 0.6rem;
}}
.day-label {{
  font-size: 0.75rem;
  color: var(--text-dim);
  width: 6.5rem;
  text-align: right;
  flex-shrink: 0;
  font-variant-numeric: tabular-nums;
}}
.day-bar-wrap {{
  flex: 1;
  height: 18px;
  background: var(--bar-bg);
  border-radius: 4px;
  position: relative;
  overflow: hidden;
}}
.day-seg {{
  position: absolute;
  top: 0;
  height: 100%;
  background: var(--on);
  border-radius: 2px;
  opacity: 0.85;
}}
.day-pct {{
  font-size: 0.75rem;
  color: var(--text-dim);
  width: 3rem;
  text-align: right;
  flex-shrink: 0;
  font-variant-numeric: tabular-nums;
}}
.hour-ticks {{
  display: flex;
  align-items: center;
  gap: 0.6rem;
  margin-top: 0.3rem;
}}
.hour-ticks-spacer {{
  width: 6.5rem;
  flex-shrink: 0;
}}
.hour-ticks-bar {{
  flex: 1;
  display: flex;
  justify-content: space-between;
}}
.hour-ticks-end {{
  width: 3rem;
  flex-shrink: 0;
}}
.hour-tick {{
  font-size: 0.65rem;
  color: var(--text-dim);
  opacity: 0.6;
}}

/* Heatmap */
.heatmap-table {{
  width: 100%;
  border-collapse: collapse;
  margin-top: 0.75rem;
}}
.heatmap-table th {{
  font-size: 0.72rem;
  color: var(--text-dim);
  font-weight: 500;
  padding: 0.4rem 0.5rem;
  text-align: center;
}}
.heatmap-table th:first-child {{
  text-align: left;
}}
.heatmap-table td {{
  padding: 0.3rem 0.5rem;
  text-align: center;
}}
.heatmap-table td:first-child {{
  text-align: left;
  font-size: 0.85rem;
  font-weight: 500;
  white-space: nowrap;
}}
.heatmap-cell {{
  display: inline-block;
  width: 100%;
  min-width: 2.5rem;
  padding: 0.35rem 0;
  border-radius: 5px;
  font-size: 0.75rem;
  font-weight: 600;
  font-variant-numeric: tabular-nums;
}}

/* Events */
.events-list {{
  max-height: 500px;
  overflow-y: auto;
}}
.event-row {{
  display: flex;
  align-items: center;
  padding: 0.45rem 0;
  border-bottom: 1px solid var(--border);
  gap: 1rem;
  font-size: 0.85rem;
}}
.event-row:last-child {{
  border-bottom: none;
}}
.event-time {{
  color: var(--text-dim);
  font-variant-numeric: tabular-nums;
  width: 10rem;
  flex-shrink: 0;
}}
.event-action {{
  width: 5rem;
  flex-shrink: 0;
  font-weight: 600;
}}
.event-on {{ color: var(--on); }}
.event-off {{ color: var(--text-dim); }}
.event-entity {{ color: var(--text); }}

::-webkit-scrollbar {{ width: 6px; }}
::-webkit-scrollbar-track {{ background: var(--surface); }}
::-webkit-scrollbar-thumb {{ background: var(--border); border-radius: 3px; }}
</style>
</head>
<body>
<div class="container">
  <h1>Light Activity Report</h1>
  <div class="date-range">{date_range}</div>
"""


def _html_summary(total_entities: int, num_days: int, entity_data: list[dict]) -> str:
    most = max(entity_data, key=lambda e: e["avg_on"]) if entity_data else None
    least = min(entity_data, key=lambda e: e["avg_on"]) if entity_data else None
    most_name = html.escape(most["name"]) if most else "&mdash;"
    most_pct = f'{most["avg_on"]:.0f}%' if most else "&mdash;"
    least_name = html.escape(least["name"]) if least else "&mdash;"
    least_pct = f'{least["avg_on"]:.0f}%' if least else "&mdash;"
    return f"""  <div class="summary-grid">
    <div class="card">
      <div class="card-label">Lights Tracked</div>
      <div class="card-value">{total_entities}</div>
      <div class="card-detail">{num_days} days of data</div>
    </div>
    <div class="card">
      <div class="card-label">Most Active</div>
      <div class="card-value" style="color:var(--on);font-size:1.15rem">{most_name}</div>
      <div class="card-detail">avg {most_pct} on per day</div>
    </div>
    <div class="card">
      <div class="card-label">Least Active</div>
      <div class="card-value" style="font-size:1.15rem">{least_name}</div>
      <div class="card-detail">avg {least_pct} on per day</div>
    </div>
  </div>
"""


def _html_timelines(entity_data: list[dict]) -> str:
    lines = [
        '  <div class="section">',
        '    <h2>Activity Timelines</h2>',
        '    <p class="subtitle">Each row is one day. '
        'Yellow segments show when the light was on.</p>',
    ]

    for ed in entity_data:
        lines.append('    <div class="entity-card">')
        lines.append(
            f'      <div class="entity-header">'
            f'<span class="entity-name">{html.escape(ed["name"])}</span>'
            f'<span class="entity-avg">avg {ed["avg_on"]:.0f}% on</span>'
            f'</div>'
        )

        for dr in ed["days"]:
            seg_html = ""
            for start_pct, end_pct in dr["segments"]:
                w = end_pct - start_pct
                seg_html += (
                    f'<div class="day-seg" '
                    f'style="left:{start_pct:.2f}%;width:{w:.2f}%"></div>'
                )
            lines.append(
                f'      <div class="day-row">'
                f'<span class="day-label">{html.escape(dr["label"])}</span>'
                f'<div class="day-bar-wrap">{seg_html}</div>'
                f'<span class="day-pct">{dr["pct"]:.0f}%</span>'
                f'</div>'
            )

        # Hour tick marks
        lines.append('      <div class="hour-ticks">')
        lines.append('        <span class="hour-ticks-spacer"></span>')
        lines.append('        <div class="hour-ticks-bar">')
        for h in (0, 3, 6, 9, 12, 15, 18, 21, 24):
            if h == 0:
                label = "12a"
            elif h < 12:
                label = f"{h}a"
            elif h == 12:
                label = "12p"
            elif h == 24:
                label = ""
            else:
                label = f"{h - 12}p"
            lines.append(f'          <span class="hour-tick">{label}</span>')
        lines.append('        </div>')
        lines.append('        <span class="hour-ticks-end"></span>')
        lines.append('      </div>')

        lines.append('    </div>')

    lines.append('  </div>')
    return "\n".join(lines)


def _heatmap_color(pct: float) -> str:
    if pct < 1:
        return "var(--bar-bg)"
    t = min(pct / 60, 1.0)
    r = int(30 + t * (245 - 30))
    g = int(33 + t * (197 - 33))
    b = int(48 + t * (66 - 48))
    a = 0.35 + t * 0.65
    return f"rgba({r},{g},{b},{a:.2f})"


def _html_heatmap(entity_data: list[dict], days) -> str:
    lines = [
        '  <div class="section">',
        '    <h2>Daily On-Time Heatmap</h2>',
        '    <p class="subtitle">Percentage of each day the light was on.</p>',
        '    <div style="overflow-x:auto">',
        '    <table class="heatmap-table">',
        '      <tr><th></th>',
    ]

    for day_start, _day_end, _label in days:
        short = day_start.astimezone(LOCAL_TZ).strftime("%a %-m/%-d")
        lines.append(f'        <th>{html.escape(short)}</th>')
    lines.append('      </tr>')

    for ed in entity_data:
        lines.append(f'      <tr><td>{html.escape(ed["name"])}</td>')
        for dr in ed["days"]:
            color = _heatmap_color(dr["pct"])
            text_color = "#fff" if dr["pct"] > 5 else "var(--text-dim)"
            val = f'{dr["pct"]:.0f}%' if dr["pct"] >= 1 else "&mdash;"
            lines.append(
                f'        <td><span class="heatmap-cell" '
                f'style="background:{color};color:{text_color}">'
                f'{val}</span></td>'
            )
        lines.append('      </tr>')

    lines.append('    </table>')
    lines.append('    </div>')
    lines.append('  </div>')
    return "\n".join(lines)


def _html_events(events: list[dict]) -> str:
    lines = [
        '  <div class="section">',
        f'    <h2>Recent Events</h2>',
        f'    <p class="subtitle">Last {len(events)} state changes.</p>',
        '    <div class="card events-list">',
    ]

    if not events:
        lines.append(
            '      <div style="padding:1rem;color:var(--text-dim)">No events.</div>'
        )
    else:
        for ev in events:
            ts_str = ev["time"].astimezone(LOCAL_TZ).strftime("%a %b %-d  %H:%M:%S")
            cls = "event-on" if ev["action"] == "turn_on" else "event-off"
            icon = "&#9654;" if ev["action"] == "turn_on" else "&#9632;"
            lines.append(
                f'      <div class="event-row">'
                f'<span class="event-time">{ts_str}</span>'
                f'<span class="event-action {cls}">{icon} {ev["action"]}</span>'
                f'<span class="event-entity">{html.escape(ev["entity"])}</span>'
                f'</div>'
            )

    lines.append('    </div>')
    lines.append('  </div>')
    return "\n".join(lines)


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Generate an HTML report of HA light activity.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--days", type=int, default=7,
        help="number of past full days to include (excludes today)",
    )
    parser.add_argument(
        "--output", type=str, default="out/light_activity.html",
        help="output HTML file path",
    )
    args = parser.parse_args()

    today_local = datetime.now(LOCAL_TZ).replace(
        hour=0, minute=0, second=0, microsecond=0
    )

    # Build list of (day_start_utc, day_end_utc, label) newest-first
    days = []
    for i in range(1, args.days + 1):
        day_start = today_local - timedelta(days=i)
        day_end = day_start + timedelta(days=1)
        label = day_start.strftime("%a %b %-d")
        days.append((
            day_start.astimezone(timezone.utc),
            day_end.astimezone(timezone.utc),
            label,
        ))

    overall_start = days[-1][0]
    overall_end   = days[0][1]

    print(f"Fetching {args.days} days of history from {HA_URL} ...")

    try:
        history = fetch_history(HA_ENTITIES, overall_start, overall_end)
    except urllib.error.URLError as e:
        print(f"ERROR: Could not reach Home Assistant: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}")
        raise

    page = generate_html(history, HA_ENTITIES, days)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(page)
    print(f"Wrote {out_path.resolve()}")


if __name__ == "__main__":
    main()
