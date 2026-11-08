# lights

Generates a realistic on/off schedule for your home's lights while you're on vacation — making the house look occupied.

It's a macOS menubar app that records light usage directly from Lutron into SQLite, builds a schedule by empirical-day resampling, and executes it through verified local LEAP calls. Existing InfluxDB history can be imported once. A legacy Home Assistant backend remains available. It also publishes a virtual HomeKit switch you can flip to arm/disarm the schedule from the Home app.

## How it works

1. **Record usage** — observes Lutron switches continuously while the app runs and stores local history; imports existing InfluxDB data on the first launch after migration
2. **Generate schedule** — for each block of each vacation day, samples a real historical day (matching day-of-week, weighted toward seasonally close donors) and replays its switch events with small jitter
3. **Execute** — when the virtual switch is turned on, the app calls the configured light-control backend at each event time; when it's off, everything is left off

The schedule is regenerated nightly. Every generated day is a perturbation of something that actually happened in your home, which beat an LSTM and a Neural-Hawkes hazard model on realism metrics (hourly on-rate, switch-frequency, KL divergence vs. history).

## Prerequisites

- macOS 26 (Tahoe) or later
- [Swift](https://www.swift.org/install/) 6.3+ toolchain (Xcode or command-line tools) to build
- [Node.js](https://nodejs.org/) — vendored into the app bundle at build time for the virtual HomeKit switch
- A paired Caséta hub for direct Lutron operation; an existing HA/InfluxDB installation is needed only to import old history (or use the legacy backend)
- A Mac that stays on while you're away (it runs the menubar app and the switch)

## Build

```bash
cd menubar
./build.sh
```

This compiles the app and bundles the Node.js virtual-switch daemon into `LightsMenubar.app`. Copy that to `/Applications` (or launch it in place) and add it to your login items so it starts on boot.

## Configure

Launch the app, click the menubar icon, and open settings using the button at the top of the popover. You'll provide:

- **Home Assistant URL** and a **Long-Lived Access Token** (HA **Profile → Security → Long-Lived Access Tokens**). The token is stored in the macOS Keychain.
- **InfluxDB** host/port/user/password and database (from HA **Settings → Add-ons → InfluxDB → Open Web UI → InfluxDB Admin → Users**). The password is stored in the Keychain.
- The **light entities** to control (fetched live from Home Assistant).
- **Schedule** knobs — vacation length, history window, blocks per day, and jitter.

Configuration is saved to `~/Library/Application Support/lights-menubar/config.json`; secrets live in the Keychain.

## Direct Lutron control

The app supports Caséta DivaSmartSwitch devices using the certificate-verified,
dependency-free LEAP implementation in `lutron/`.

1. Open Configure and enable **Control lights directly through Lutron**.
2. Click **Pair with hub**. When prompted, press the small button on the back of
   the hub within 90 seconds. The app verifies the new credentials, stores them in
   Keychain, and discovers your switches. Cancel and retry are available.
   To reuse a previously exported pairing, choose **More → Import existing pairing…**.
3. Review the selected lights and their **Lutron switch** mappings, then Save.
   Pairing credentials are stored in macOS Keychain; they are never bundled or
   passed on command lines. Existing schedule/history entity IDs remain unchanged.

Commands use mutual TLS and read back the resulting state before the executor
marks them successful. Missing mappings or TLS failures surface as errors; there
is no automatic fallback to HA when Lutron is selected. Existing configurations
continue to use HA until explicitly switched in settings.

**Local history is now the default for Lutron.** On first launch with the new
build, the app imports the configured history window from InfluxDB and records
future switch observations directly into
`~/Library/Application Support/lights-menubar/history.sqlite`. Keep InfluxDB
available until Settings reports a successful import and Refresh schedule succeeds.
Import failures are visible and retryable under **Usage history**; repeated imports
are idempotent. After successful migration, scheduling uses SQLite without calling
InfluxDB. The legacy source remains selectable in settings.

The recorder runs while away mode is off as well as on, and reconnects with bounded
backoff. It receives live changes and reads all selected switches every 15 seconds.
Only full Pacific-calendar days with continuous coverage for every selected light
are eligible as new schedule donors. App downtime, disconnects, unknown away state,
and vacation playback break coverage; a heartbeat gap longer than 35 seconds also
breaks it. Quiet but fully observed days are eligible. The Mac must stay awake and
the app must remain running to collect complete days. On generation failure the
previous schedule file is preserved.

Historical imports retain HA's existing state timeline and assume coverage from
the first known event to the migration boundary; past HA outages and vacation
periods cannot be identified retroactively from on/off events alone. Import never
extends beyond the first local-recorder/import start, so later imports cannot fill
local recording gaps or add generated vacation activity to donor days.

SQLite uses WAL journaling. Back up the app-support directory while the app is
closed, or use SQLite's backup mechanism. System details show recorder health and
the last observation time. No new Node dependencies were added.

Developer builds can set `LIGHTS_NODE_BIN` and `LIGHTS_LUTRON_DIR` to an absolute
Node executable and the repository's `lutron/` directory. Release builds bundle
these automatically. Run protocol/TLS tests with `cd lutron && npm test`.

## Usage

Pair the app's virtual HomeKit switch from the iOS/macOS **Home** app (the pairing PIN is shown in the menubar until it's paired). Then:

- **Turn the switch on** to arm the vacation schedule — the app replays lights until you turn it off.
- **Turn the switch off** to stop; all lights are left off.

Use **Refresh schedule** in the popover to regenerate the schedule. The menubar's right-click menu offers switch-daemon status, **Restart switch daemon**, and **Quit**.

## Tuning

The schedule generator (`Resampler`) is controlled by the **Schedule** section in Configure:

- **Blocks** — split each day into N equal-width time blocks, drawing an independent donor per block. Defaults to 2 (morning/evening split), which empirically beats both whole-day replay (1 block) and finer splits.
- **Jitter** — random ±M-minute offset applied to each replayed event. Defaults to 10.
- **History days** — how far back to pull donor days from. Defaults to 183 (~6 months).

For reproducible output while debugging, the headless CLI accepts a fixed seed:

```bash
.build/debug/LightsMenubar --resample <start YYYY-MM-DD> <end YYYY-MM-DD> <data.csv> <entity_map.json> <out.json> [seed]
```

## Development

Run the unit tests (they cover the resampler and CLI parsing):

```bash
cd menubar
swift test
```

## Layout

| Path | Description |
|------|-------------|
| `menubar/Sources/LightsMenubar/` | The macOS menubar app (SwiftUI) |
| `menubar/Sources/LightsMenubar/InfluxClient.swift` | Fetches light history from InfluxDB |
| `menubar/Sources/LightsMenubar/Resampler.swift` | Builds the vacation schedule via empirical-day resampling |
| `menubar/Sources/LightsMenubar/ScheduleExecutor.swift` | Executes the schedule via the Home Assistant REST API |
| `menubar/Sources/LightsMenubar/SwitchDaemon.swift` | Supervises the bundled virtual HomeKit switch |
| `menubar/Tests/LightsMenubarTests/` | Unit tests |
| `switch/` | Node.js virtual HomeKit switch daemon (`hap-nodejs`), bundled into the app |
| `menubar/build.sh` | Builds the app and bundles the switch daemon + Node.js |
