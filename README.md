# lights

Generates a realistic on/off schedule for your home's lights while you're on vacation — making the house look occupied.

Uses Home Assistant + InfluxDB for historical data, empirical-day resampling to build the schedule, and a daemon that calls the Home Assistant REST API to execute it.

## How it works

1. **Fetch data** — pulls ~6 months of light state history from InfluxDB
2. **Generate schedule** — for each block of each vacation day, samples a real historical day (matching day-of-week, weighted toward seasonally close donors) and replays its switch events with small jitter
3. **Run daemon** — executes the schedule by calling the Home Assistant REST API at each event time

The resampling approach beat an LSTM and a Neural-Hawkes hazard model on realism metrics (hourly on-rate, switch-frequency, KL divergence vs. history) — every generated day is a perturbation of something that actually happened in your home.

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

**2. Configure credentials**

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

**3. Configure your light entities**

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
./generate_model.sh 2026-04-01 2026-04-08
```

This fetches fresh data and generates `out/schedule_events.json`.

Then start the daemon (on the machine that will stay home):

```bash
./start_vacation_daemon.sh
```

Monitor progress:

```bash
tail -f out/vacation_daemon.log
```

Stop the daemon early:

```bash
./stop_vacation_daemon.sh
```

## Tuning

`generate_resample.py` accepts a few knobs:

- `--blocks N` — split each day into N equal-width time blocks, drawing an independent donor per block. Defaults to 2 (splits morning/evening), which empirically beats both whole-day replay (`--blocks 1`) and finer splits.
- `--jitter-minutes M` — random offset (±M minutes) applied to each replayed event. Defaults to 10.
- `--seed S` — fix the RNG for reproducible output.

## Files

| File | Description |
|------|-------------|
| `fetch_ha_data.py` | Fetches light history from InfluxDB |
| `generate_resample.py` | Builds the vacation schedule via empirical-day resampling |
| `vacation_daemon.py` | Executes the schedule via the Home Assistant REST API |
| `configure.py` | Interactive entity selection → `config.json` |
| `light_activity.py` | Generates an HTML activity report for recent days |
| `generate_model.sh` | Runs fetch + generate in one step |
| `start_vacation_daemon.sh` | Starts the daemon in the background |
| `stop_vacation_daemon.sh` | Stops the daemon if it is running |
| `out/schedule_events.json` | Generated on/off events |
