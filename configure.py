#!/usr/bin/env python3
"""
Interactive configuration script.

Queries Home Assistant for all light and switch entities and lets you
select which ones to include in config.json.

Usage:
    uv run configure.py
"""

import json
import os
import urllib.request
from pathlib import Path

# Load .env
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
    raise SystemExit("ERROR: HA_TOKEN is not set in .env")


def get_states():
    req = urllib.request.Request(
        f"{HA_URL}/api/states",
        headers={"Authorization": f"Bearer {HA_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def main():
    print(f"Connecting to Home Assistant at {HA_URL}...\n")
    states = get_states()

    # Filter to light and switch domains, sorted by entity_id
    entities = sorted(
        [s for s in states if s["entity_id"].split(".")[0] in ("light", "switch")],
        key=lambda s: s["entity_id"],
    )

    if not entities:
        raise SystemExit("No light or switch entities found.")

    print(f"Found {len(entities)} light/switch entities:\n")
    for i, s in enumerate(entities):
        name = s["attributes"].get("friendly_name", "")
        print(f"  {i+1:3}.  {s['entity_id']:<45}  {name}")

    print()
    print("Enter the numbers of the entities to include in config.json.")
    print("Separate with commas or spaces (e.g. 1,3,5 or 1 3 5):")
    raw = input("> ").strip()

    # Parse selection
    tokens = raw.replace(",", " ").split()
    selected = []
    for token in tokens:
        try:
            idx = int(token) - 1
            if 0 <= idx < len(entities):
                selected.append(entities[idx]["entity_id"])
            else:
                print(f"  Skipping out-of-range number: {token}")
        except ValueError:
            print(f"  Skipping invalid input: {token}")

    if not selected:
        raise SystemExit("No entities selected. config.json not written.")

    config = {"entities": selected}
    config_path = Path(__file__).parent / "config.json"
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    print(f"\nWrote {len(selected)} entities to config.json:")
    for e in selected:
        print(f"  {e}")


if __name__ == "__main__":
    main()
