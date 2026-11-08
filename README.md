# lights

Generates a realistic on/off schedule for your home's lights while you're on vacation — making the house look occupied.

It's a macOS menubar app that records light usage directly from Lutron into SQLite, builds a schedule by empirical-day resampling, and executes it through verified local LEAP calls. It also publishes a virtual HomeKit switch you can flip to arm/disarm the schedule from the Home app.

## How it works

1. **Record usage** — observes Lutron switches continuously while the app runs and stores local history
2. **Generate schedule** — for each block of each vacation day, samples a real historical day (matching day-of-week, weighted toward seasonally close donors) and replays its switch events with small jitter
3. **Execute** — when the virtual switch is turned on, the app calls Lutron at each event time; disarming sends off commands to the selected and scheduled lights

The schedule is regenerated at launch, after saving settings, on manual refresh, and daily at 4 AM Pacific. Generation uses complete historical days from the local database. Home Assistant and InfluxDB are not required or contacted.

## Architecture

The Swift app owns configuration, recording, schedule generation, and execution.
It launches Node.js processes for two separate jobs:

| Component | Responsibility |
|-----------|----------------|
| `LutronClient` → `lutron/app-helper.js` | Pair with and discover the hub, monitor switches, and send verified LEAP commands over mutual TLS. Requests and credentials travel over stdin; responses and monitor observations return as JSON lines. |
| `LutronRecorder` → `HistoryStore` | Keep a monitor process connected, store state changes in SQLite, and track explicit recording coverage for each light. |
| `ScheduleGenerator` → `Resampler` | Read eligible local history and atomically write `schedule_events.json`. `NightlyScheduler` triggers the daily refresh. |
| `SwitchDaemon` → `switch/index.js` | Supervise the persistent `hap-nodejs` process that publishes the virtual HomeKit switch and writes `state.json`. |
| `StateWatcher` → `ScheduleExecutor` / `SchedulePlayback` | Read away-mode state, watch the schedule file, reconcile each light to its latest due action, and retry failed commands. |

The HomeKit daemon only supplies the away-mode toggle. Physical light control uses
the separate Lutron helper. Monitoring uses a long-running helper process; pairing,
discovery, and control requests use separate helper invocations.

The executor serializes commands and confirms each requested state by reading it
back from the hub. Delayed timers reconcile to the latest due state instead of
replaying every missed transition. Failed commands remain pending and retry after
five seconds. Disarming sends explicit off commands; ordinary manual light use
remains possible while away mode is off. An unreadable away-state file suspends
playback and learning coverage.

### Local storage

| Location | Contents |
|----------|----------|
| `~/Library/Application Support/lights-menubar/config.json` | Hub address, stable light IDs mapped to Lutron zones, and schedule parameters |
| `~/Library/Application Support/lights-menubar/history.sqlite` | State changes, per-light coverage intervals, and metadata; SQLite WAL mode |
| `~/Library/Application Support/lights-menubar/schedule_events.json` | Generated events with `time`, `entity_id`, and `action` (`turn_on` / `turn_off`) |
| macOS Keychain, service `com.nicklee.lights-menubar`, account `lutron_identity` | Lutron CA, client certificate, and private key |
| `~/Library/Application Support/lights-virtual-switch/` | Away state and HomeKit identity/pairing data; see [switch/README.md](switch/README.md) |

Stable light IDs connect history and schedule events to explicitly configured
Lutron zone paths. Control targets are never inferred from a light's display name
at execution time.

## Prerequisites

- macOS 26 (Tahoe) or later
- [Swift](https://www.swift.org/install/) 6.3+ toolchain (Xcode or command-line tools) to build
- [Node.js](https://nodejs.org/) — vendored into the app bundle at build time for the HomeKit daemon and Lutron helper
- A paired Caséta hub for direct Lutron operation
- A Mac that stays on while you're away (it runs the menubar app and the switch)

## Build

```bash
cd menubar
./build.sh
```

This compiles the release app and bundles the HomeKit daemon, its dependencies, the Lutron helper, and a pinned Node.js runtime into `menubar/build/LightsMenubar.app`. The build signs the bundle with an available Developer ID identity, falling back to ad-hoc signing. Copy that to `/Applications` and launch it. In the app’s settings, enable **Launch at login** under **Startup** to open it automatically after you log in. This setting applies immediately without clicking Save. If macOS requires approval, use **Open Login Items…** to allow it in System Settings. It does not run before login.

## Configure

Launch the app, click the menubar icon, and open settings using the button at the top of the popover. You'll provide:

- **Lutron hub address** and pairing credentials (stored in Keychain).
- The **lights** to control and their discovered Lutron zone mappings.
- **Vacation window** — the number of days to generate. Other schedule parameters are stored in `config.json`.

Configuration is saved to `~/Library/Application Support/lights-menubar/config.json`; secrets live in the Keychain.

## Direct Lutron control

The app supports Caséta DivaSmartSwitch devices using the certificate-verified,
dependency-free LEAP implementation in `lutron/`.

1. Open Configure and enter the Lutron hub address.
2. Click **Pair with hub**. When prompted, press the small button on the back of
   the hub within 90 seconds. The app verifies the new credentials, stores them in
   Keychain, and discovers your switches. Cancel and retry are available.
   To reuse a previously exported pairing, choose **More → Import existing pairing…**.
3. Review the selected lights and their **Lutron switch** mappings, then Save.
   Pairing credentials are stored in macOS Keychain; they are never bundled or
   passed on command lines. Existing schedule/history entity IDs remain unchanged.

Commands use mutual TLS and read back the resulting state before the executor
marks them successful. Missing mappings or TLS failures surface as errors; there
is no alternate control backend.

History and schedule generation use the local SQLite database at
`~/Library/Application Support/lights-menubar/history.sqlite`.
Existing imported history and stable light IDs are preserved.

The recorder runs while away mode is off as well as on, and reconnects with bounded
backoff. It receives live changes and reads all selected switches every 15 seconds.
Only full Pacific-calendar days with continuous coverage for every selected light
are eligible as new schedule donors. App downtime, disconnects, unknown away state,
and vacation playback break coverage; a heartbeat gap longer than 35 seconds also
breaks it. Quiet but fully observed days are eligible. The Mac must stay awake and
the app must remain running to collect complete days. On generation failure the
previous schedule file is preserved.

SQLite uses WAL journaling. Back up the app-support directory while the app is
closed, or use SQLite's backup mechanism. System details show recorder health and
the last observation time. A fresh database needs at least one complete recorded day before schedule generation can succeed; there is no history-import UI.

Developer builds can set `LIGHTS_NODE_BIN` to an absolute Node executable,
`LIGHTS_LUTRON_DIR` to the repository's `lutron/` directory, and
`LIGHTS_SWITCH_DIR` to its `switch/` directory (with dependencies installed).
Release builds bundle these resources automatically.

## Usage

Pair the app's virtual HomeKit switch from the iOS/macOS **Home** app (the pairing PIN is shown in the menubar until it's paired). Then:

- **Turn the switch on** to arm the vacation schedule — the app replays lights until you turn it off.
- **Turn the switch off** to stop playback and turn the selected and scheduled lights off. You can then use the lights normally.

Use **Refresh schedule** in the popover to regenerate the schedule. The menubar's right-click menu offers switch-daemon status, **Restart switch daemon**, and **Quit**.

## Tuning

Settings exposes the vacation window (1–30 days). The remaining generator parameters live under `schedule` in `config.json`; restart the app after editing the file:

- **`blocks`** — split each day into N equal-width time blocks, drawing an independent donor per block. Defaults to 2 (morning/evening split), which empirically beats both whole-day replay (1 block) and finer splits.
- **`jitterMinutes`** — random ±M-minute offset applied to each replayed event. Defaults to 10.
- **`historyDays`** — how far back to pull donor days from. Defaults to 183 (~6 months).

For reproducible output while debugging, the headless CLI accepts a fixed seed:

```bash
.build/debug/LightsMenubar --resample <start YYYY-MM-DD> <end YYYY-MM-DD> <data.csv> <entity_map.json> <out.json> [seed]
```

## Development

Run the Swift tests for history coverage, configuration, resampling, playback, and subprocess handling:

```bash
cd menubar
swift test
```

Run the Node suites from the repository root:

```bash
npm --prefix lutron test
npm --prefix switch test
```

## Layout

| Path | Description |
|------|-------------|
| `menubar/Sources/LightsMenubar/` | The macOS menubar app (SwiftUI) |
| `lutron/` | Dependency-free Node.js LEAP pairing, discovery, monitoring, and verified control |
| `menubar/Sources/LightsMenubar/LutronRecorder.swift` | Monitors switches and tracks learning coverage |
| `menubar/Sources/LightsMenubar/HistoryStore.swift` | Stores local light history and recording coverage |
| `menubar/Sources/LightsMenubar/Resampler.swift` | Builds the vacation schedule via empirical-day resampling |
| `menubar/Sources/LightsMenubar/ScheduleExecutor.swift` | Executes the schedule via verified local Lutron LEAP calls |
| `menubar/Sources/LightsMenubar/SwitchDaemon.swift` | Supervises the bundled virtual HomeKit switch |
| `menubar/Tests/LightsMenubarTests/` | Unit tests |
| `switch/` | Node.js virtual HomeKit switch daemon (`hap-nodejs`), bundled into the app |
| `menubar/build.sh` | Builds and signs the app with the HomeKit daemon, Lutron helper, and Node.js |
