# lights

Learns your home's light usage patterns from historical data and generates a realistic on/off schedule to run while you're on vacation — making the house look occupied.

Uses Home Assistant + InfluxDB for data, an LSTM model for pattern learning, and a daemon that calls the Home Assistant REST API to execute the schedule.

## How it works

1. **Fetch data** — pulls 3 months of light state history from InfluxDB
2. **Train model** — an LSTM learns your daily/weekly light patterns
3. **Generate schedule** — produces a realistic on/off schedule for your vacation dates
4. **Run daemon** — executes the schedule by calling the Home Assistant REST API at each event time

## Prerequisites

- [uv](https://docs.astral.sh/uv/) — Python package manager
- Home Assistant with the InfluxDB add-on installed and recording light states
- A machine that stays on while you're away (the daemon runs there)

## Setup

**1. Clone the repo and install dependencies**

```bash
git clone <repo-url>
cd lights
uv sync
```

**2. Register the Jupyter kernel**

```bash
uv run python -m ipykernel install --user --name lights --display-name "lights"
```

**3. Configure credentials**

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

```ini
HA_URL=http://homeassistant.local:8123
HA_TOKEN=<long-lived access token from HA Profile → Security>
INFLUXDB_HOST=homeassistant.local
INFLUXDB_PORT=8086
INFLUXDB_USER=<influxdb username>
INFLUXDB_PASSWORD=<influxdb password>
INFLUXDB_DATABASE=homeassistant
```

Get a Long-Lived Access Token from Home Assistant: **Profile → Security → Long-Lived Access Tokens**.

Get InfluxDB credentials from Home Assistant: **Settings → Add-ons → InfluxDB → Open Web UI → InfluxDB Admin → Users**.

**4. Configure your light entities**

Run the interactive configuration script, which queries Home Assistant and lets you choose which lights to include:

```bash
uv run configure.py
```

This writes `config.json`. Alternatively, copy `config.json.example` and edit it manually:

```bash
cp config.json.example config.json
```

## Usage

Before you leave, run:

```bash
./run.sh 2026-04-01 2026-04-08
```

This fetches fresh data, retrains the model, and generates `out/schedule_events.json`.

To review the generated schedule visually:

```bash
uv run jupyter lab out/lights_executed.ipynb
```

Then start the daemon (on the machine that will stay home):

```bash
nohup uv run vacation_daemon.py out/schedule_events.json > out/vacation_daemon.log 2>&1 &
```

Monitor progress:

```bash
tail -f out/vacation_daemon.log
```

Stop the daemon early:

```bash
kill $(pgrep -f vacation_daemon.py)
```

## Files

| File | Description |
|------|-------------|
| `fetch_ha_data.py` | Fetches light history from InfluxDB |
| `lights.ipynb` | Trains the LSTM model and generates the vacation schedule |
| `vacation_daemon.py` | Executes the schedule via the Home Assistant REST API |
| `run.sh` | Runs fetch + train + generate in one step |
| `out/schedule_events.json` | Generated on/off events (created by notebook) |
| `out/lights_executed.ipynb` | Executed notebook with all outputs and charts |
