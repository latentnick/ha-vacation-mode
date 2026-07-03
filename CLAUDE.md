# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project makes a home look occupied while the owner is away. It fetches historical light-usage data from Home Assistant via InfluxDB, generates a realistic vacation light schedule via empirical-day resampling, and executes it via the Home Assistant REST API.

It is a **macOS menubar app** (SwiftUI, in `menubar/`) that does all of this natively. A bundled **Node.js virtual HomeKit switch** (`switch/`) lets the user arm/disarm the schedule from the Home app. (An earlier Python implementation of the pipeline was removed once the Swift port reached parity — see git history if you need it.)

## Architecture

### Data flow (all in `menubar/Sources/LightsMenubar/`)
1. `InfluxClient.swift` — pulls light state history from InfluxDB into `RawStateRow`s
2. `Resampler.swift` — for each block of each vacation day, samples a real historical day (day-of-week match, weighted by seasonal proximity) and replays that donor's switch events within the block with small jitter. Produces the schedule events.
3. `ScheduleGenerator.swift` / `NightlyScheduler.swift` — orchestrate fetch + generate; the schedule is regenerated nightly and written to `~/Library/Application Support/lights-menubar/schedule_events.json`
4. `ScheduleExecutor.swift` — watches the virtual switch; when armed, calls the HA REST API at each event time
5. `SwitchDaemon.swift` — supervises the bundled `switch/index.js` Node process (the HomeKit accessory)

### Key files
| File | Purpose |
|------|---------|
| `menubar/Package.swift` | SwiftPM manifest (`LightsMenubar` executable + `LightsMenubarTests`) |
| `menubar/build.sh` | Builds the app and bundles the Node switch daemon + a vendored Node.js |
| `menubar/scripts/vendor-node.sh` | Vendors a Node.js runtime for bundling |
| `switch/index.js` | Node.js virtual HomeKit switch (`hap-nodejs`) |
| `~/Library/Application Support/lights-menubar/config.json` | App config (HA URL, InfluxDB settings, entities, schedule knobs) |
| `~/Library/Application Support/lights-menubar/schedule_events.json` | Generated on/off events |
| macOS Keychain | HA long-lived token and InfluxDB password (see `KeychainStore.swift`) |

## Development Environment

- Build the app: `cd menubar && ./build.sh`
- Build only (no bundling): `cd menubar && swift build`
- Run the tests: `cd menubar && swift test`
- Headless schedule generation (debug): `LightsMenubar --resample <start> <end> <data.csv> <entity_map.json> <out.json> [seed]`

The Swift toolchain is 5.9+; the app targets macOS 13.

## Testing

`menubar/Tests/LightsMenubarTests/` holds the unit tests. `ResamplerTests` covers the schedule generator's invariants (deterministic given a seed, events sorted, no consecutive same-state events per entity, all lights off at the end, entity-id mapping, jitter bounds) and `ResampleCLITests` covers the CLI's CSV/timestamp parsing. These replace the old approach of diffing the Swift output against the retired Python `generate_resample.py`.

## Home Assistant Integration

### InfluxDB (v1.8.x)
- Add-on: `hassio-addons/addon-influxdb`
- Uses InfluxQL (not Flux)
- Credentials are set in the addon's Chronograf UI, not HA login credentials
- Light states stored in the `state` measurement with `entity_id` field and `state` field (`"on"`/`"off"`)

### REST API
- Service calls: `POST /api/services/switch/turn_on` and `turn_off`
- Auth: `Authorization: Bearer <token>` header
- Token from: HA Profile → Security → Long-Lived Access Tokens

### Entity naming
- InfluxDB stores entities without domain prefix (e.g. `office_main_lights`)
- HA REST API uses full entity IDs with domain (e.g. `switch.office_main_lights`)
- The app's `entityMap` (short name → full HA entity ID) holds the mapping

## Schedule events

Schedule events are `{time, entity_id, action}` objects sorted by time. `entity_id` is the full HA entity ID (e.g. `switch.office_main_lights`). `action` is `"turn_on"` or `"turn_off"`. Timestamps are US/Pacific.

## Generator

`Resampler` draws an independent donor day per time block within each vacation day (default 2 blocks = morning/evening split). For each block it aligns simulated state to the donor's state at the block boundary, then replays the donor's switch events within that block with ±10 minute jitter. A final pass after global sort drops events that don't change state (jitter can reorder events across midnight).

Empirically this beats whole-day replay (1 block) and finer splits on hourly on-rate MAD, KL divergence vs. history, and switch-count error.
