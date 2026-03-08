#!/usr/bin/env python3
"""
Vacation light daemon — runs on Mac Studio during vacation.

Reads schedule_events.json and calls the Home Assistant REST API
to turn lights on/off at each scheduled time.

Setup:
    Copy schedule_events.json and this file to the Mac Studio, then run:

    HA_URL=http://homeassistant.local:8123 \
    HA_TOKEN=<long-lived-access-token> \
    nohup uv run vacation_daemon.py out/schedule_events.json > out/vacation_daemon.log 2>&1 &

    Get a Long-Lived Access Token from:
    Home Assistant → Profile → Security → Long-Lived Access Tokens

To check progress:
    tail -f vacation_daemon.log

To stop early:
    kill $(pgrep -f vacation_daemon.py)
"""

import sys
import json
import time
import os
from datetime import datetime, timezone
from pathlib import Path
import urllib.request
import urllib.error

# Load .env if present
_env = Path(__file__).parent / ".env"
if _env.exists():
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


def call_ha_service(entity_id: str, action: str):
    domain = entity_id.split(".")[0]  # e.g. "switch" from "switch.office_main_lights"
    url = f"{HA_URL}/api/services/{domain}/{action}"
    data = json.dumps({"entity_id": entity_id}).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {HA_TOKEN}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status


def log(msg: str):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def main():
    schedule_file = sys.argv[1] if len(sys.argv) > 1 else "schedule_events.json"

    with open(schedule_file) as f:
        events = json.load(f)

    now = datetime.now(timezone.utc)
    future_events = [e for e in events if datetime.fromisoformat(e["time"]) > now]

    log(f"Loaded {len(events)} events, {len(future_events)} in the future")

    if not future_events:
        log("No future events. Exiting.")
        return

    for event in future_events:
        event_time = datetime.fromisoformat(event["time"])
        wait = (event_time - datetime.now(timezone.utc)).total_seconds()

        if wait > 0:
            local_time = event_time.astimezone().strftime("%Y-%m-%d %H:%M %Z")
            log(f"Sleeping {wait/3600:.1f}h until {local_time} → {event['action']} {event['entity_id']}")
            time.sleep(wait)

        log(f"Executing: {event['action']} {event['entity_id']}")
        try:
            status = call_ha_service(event["entity_id"], event["action"])
            log(f"  OK (HTTP {status})")
        except Exception as e:
            log(f"  ERROR: {e}")

    log("All events executed. Vacation over!")


if __name__ == "__main__":
    main()
