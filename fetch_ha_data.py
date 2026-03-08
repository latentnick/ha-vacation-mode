"""
Fetch light state history from InfluxDB and save to data.csv format.

Usage:
    uv run fetch_data.py

Configure connection settings via environment variables or edit the CONFIG block below.
"""

import os
import csv
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
from influxdb import InfluxDBClient

# Load .env file if present
_env = Path(__file__).parent / ".env"
if _env.exists():
    for line in _env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

# --- Configuration ---
# INFLUXDB_HOST: IP or hostname of your Home Assistant machine
# INFLUXDB_USER / INFLUXDB_PASSWORD: credentials for the InfluxDB addon
#   (set in the addon config, NOT your Home Assistant login)
INFLUXDB_HOST     = os.getenv("INFLUXDB_HOST",     "homeassistant.local")
INFLUXDB_PORT     = int(os.getenv("INFLUXDB_PORT", "8086"))
INFLUXDB_USER     = os.getenv("INFLUXDB_USER",     "")
INFLUXDB_PASSWORD = os.getenv("INFLUXDB_PASSWORD", "")
INFLUXDB_DATABASE = os.getenv("INFLUXDB_DATABASE",  "homeassistant")
OUTPUT_FILE       = os.getenv("OUTPUT_FILE",        "out/data.csv")

# Load entity list from config.json
_config_path = Path(__file__).parent / "config.json"
if not _config_path.exists():
    raise SystemExit("ERROR: config.json not found")
HA_ENTITIES = json.load(_config_path.open())["entities"]
ENTITIES    = [e.split(".", 1)[1] for e in HA_ENTITIES]  # InfluxDB names (no domain prefix)
ENTITY_MAP  = dict(zip(ENTITIES, HA_ENTITIES))            # short name -> full HA entity ID

DAYS_BACK = 90  # 3 months
# ---------------------


def fetch_light_history(client: InfluxDBClient, entity_id: str, start: datetime) -> list[dict]:
    """Query InfluxDB for state changes for a single entity since start."""
    start_rfc = start.strftime("%Y-%m-%dT%H:%M:%SZ")

    # Home Assistant writes states to the "state" measurement
    # entity_id and state are both fields; state is "on" or "off"
    query = f"""
        SELECT time, entity_id, state
        FROM "state"
        WHERE entity_id = '{entity_id}'
          AND time >= '{start_rfc}'
        ORDER BY time ASC
    """
    result = client.query(query)
    rows = []
    for point in result.get_points():
        raw = str(point.get("state", "")).strip().lower()
        if raw == "on":
            state = "1"
        elif raw == "off":
            state = "0"
        else:
            continue  # skip unknown states

        rows.append({
            "time": point["time"],
            "entity_id": point["entity_id"],
            "state.value": state,
        })
    return rows


def main():
    start = datetime.now(timezone.utc) - timedelta(days=DAYS_BACK)

    print(f"Connecting to InfluxDB at {INFLUXDB_HOST}:{INFLUXDB_PORT}, database={INFLUXDB_DATABASE}")
    client = InfluxDBClient(
        host=INFLUXDB_HOST,
        port=INFLUXDB_PORT,
        username=INFLUXDB_USER,
        password=INFLUXDB_PASSWORD,
        database=INFLUXDB_DATABASE,
    )

    all_rows = []
    for entity_id in ENTITIES:
        print(f"  Fetching {entity_id}...")
        rows = fetch_light_history(client, entity_id, start)
        print(f"    {len(rows)} records")
        all_rows.extend(rows)

    # Sort by time across all entities
    all_rows.sort(key=lambda r: r["time"])

    os.makedirs(os.path.dirname(OUTPUT_FILE), exist_ok=True)
    with open(OUTPUT_FILE, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["time", "entity_id", "state.value"], quoting=csv.QUOTE_ALL)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"\nWrote {len(all_rows)} records to {OUTPUT_FILE}")

    entity_map_file = os.path.join(os.path.dirname(OUTPUT_FILE), "entity_map.json")
    with open(entity_map_file, "w") as f:
        json.dump(ENTITY_MAP, f, indent=2)
    print(f"Wrote entity map to {entity_map_file}")


if __name__ == "__main__":
    main()
