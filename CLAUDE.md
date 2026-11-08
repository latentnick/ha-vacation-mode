# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project makes a home look occupied while the owner is away. It records light usage directly from Lutron into SQLite, generates a realistic vacation light schedule via empirical-day resampling, and executes it through verified local LEAP calls.

It is a **macOS menubar app** (SwiftUI, in `menubar/`) that does all of this natively. A bundled **Node.js virtual HomeKit switch** (`switch/`) lets the user arm/disarm the schedule from the Home app. (An earlier Python implementation of the pipeline was removed once the Swift port reached parity — see git history if you need it.)

## Architecture

### Data flow (all in `menubar/Sources/LightsMenubar/`)
1. `LutronRecorder.swift` / `HistoryStore.swift` — record local light observations and coverage into SQLite
2. `Resampler.swift` — for each block of each vacation day, samples a real historical day (day-of-week match, weighted by seasonal proximity) and replays that donor's switch events within the block with small jitter. Produces the schedule events.
3. `ScheduleGenerator.swift` / `NightlyScheduler.swift` — orchestrate local history reads + generation; the schedule is regenerated nightly and written to `~/Library/Application Support/lights-menubar/schedule_events.json`
4. `ScheduleExecutor.swift` — watches the virtual switch; when armed, calls the Lutron LEAP API at each event time
5. `SwitchDaemon.swift` — supervises the bundled `switch/index.js` Node process (the HomeKit accessory)

### Key files
| File | Purpose |
|------|---------|
| `menubar/Package.swift` | SwiftPM manifest (`LightsMenubar` executable + `LightsMenubarTests`) |
| `menubar/build.sh` | Builds the app and bundles the Node switch daemon + a vendored Node.js |
| `menubar/scripts/vendor-node.sh` | Vendors a Node.js runtime for bundling |
| `switch/index.js` | Node.js virtual HomeKit switch (`hap-nodejs`) |
| `~/Library/Application Support/lights-menubar/config.json` | App config (Lutron hub, zone mappings, entities, schedule knobs) |
| `~/Library/Application Support/lights-menubar/schedule_events.json` | Generated on/off events |
| macOS Keychain | Lutron pairing identity (see `KeychainStore.swift`) |

## Development Environment

- Build the app: `cd menubar && ./build.sh`
- Build only (no bundling): `cd menubar && swift build`
- Run the tests: `cd menubar && swift test`
- Headless schedule generation (debug): `LightsMenubar --resample <start> <end> <data.csv> <entity_map.json> <out.json> [seed]`

The Swift toolchain is 6.3+; the app targets macOS 26 (Tahoe). The package uses
swift-tools-version 6.3 and builds in the Swift 6 language mode, so strict
concurrency checking is enforced: `StateWatcher` and `NightlyScheduler` are
`@MainActor`-isolated, and `KeychainStore`'s credential cache is a `Mutex`.

## Testing

`menubar/Tests/LightsMenubarTests/` holds the unit tests. `ResamplerTests` covers the schedule generator's invariants (deterministic given a seed, events sorted, no consecutive same-state events per entity, all lights off at the end, entity-id mapping, jitter bounds) and `ResampleCLITests` covers the CLI's CSV/timestamp parsing. These replace the old approach of diffing the Swift output against the retired Python `generate_resample.py`.

## Schedule events

Schedule events are `{time, entity_id, action}` objects sorted by time. `entity_id` is a stable light ID (e.g. `switch.office_main_lights`). `action` is `"turn_on"` or `"turn_off"`. Timestamps are US/Pacific.

## Generator

`Resampler` draws an independent donor day per time block within each vacation day (default 2 blocks = morning/evening split). For each block it aligns simulated state to the donor's state at the block boundary, then replays the donor's switch events within that block with ±10 minute jitter. A final pass after global sort drops events that don't change state (jitter can reorder events across midnight).

Empirically this beats whole-day replay (1 block) and finer splits on hourly on-rate MAD, KL divergence vs. history, and switch-count error.
