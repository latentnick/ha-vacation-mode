# lights

Generates a realistic on/off schedule for your home's lights while you're on vacation — making the house look occupied.

It's a macOS menubar app that pulls ~6 months of light-state history from Home Assistant (via InfluxDB), builds a schedule by empirical-day resampling, and executes it by calling the Home Assistant REST API. It also publishes a virtual HomeKit switch you can flip to arm/disarm the schedule from the Home app.

## How it works

1. **Fetch data** — pulls light-state history from InfluxDB
2. **Generate schedule** — for each block of each vacation day, samples a real historical day (matching day-of-week, weighted toward seasonally close donors) and replays its switch events with small jitter
3. **Execute** — when the virtual switch is turned on, the app calls the Home Assistant REST API at each event time; when it's off, everything is left off

The schedule is regenerated nightly. Every generated day is a perturbation of something that actually happened in your home, which beat an LSTM and a Neural-Hawkes hazard model on realism metrics (hourly on-rate, switch-frequency, KL divergence vs. history).

## Prerequisites

- macOS 26 (Tahoe) or later
- [Swift](https://www.swift.org/install/) 6.3+ toolchain (Xcode or command-line tools) to build
- [Node.js](https://nodejs.org/) — vendored into the app bundle at build time for the virtual HomeKit switch
- Home Assistant with the InfluxDB add-on installed and recording light states
- A Mac that stays on while you're away (it runs the menubar app and the switch)

## Build

```bash
cd menubar
./build.sh
```

This compiles the app and bundles the Node.js virtual-switch daemon into `LightsMenubar.app`. Copy that to `/Applications` (or launch it in place) and add it to your login items so it starts on boot.

## Configure

Launch the app and open **Configure…** from the menubar icon. You'll provide:

- **Home Assistant URL** and a **Long-Lived Access Token** (HA **Profile → Security → Long-Lived Access Tokens**). The token is stored in the macOS Keychain.
- **InfluxDB** host/port/user/password and database (from HA **Settings → Add-ons → InfluxDB → Open Web UI → InfluxDB Admin → Users**). The password is stored in the Keychain.
- The **light entities** to control (fetched live from Home Assistant).
- **Schedule** knobs — vacation length, history window, blocks per day, and jitter.

Configuration is saved to `~/Library/Application Support/lights-menubar/config.json`; secrets live in the Keychain.

## Usage

Pair the app's virtual HomeKit switch from the iOS/macOS **Home** app (the pairing PIN is shown in the menubar until it's paired). Then:

- **Turn the switch on** to arm the vacation schedule — the app replays lights until you turn it off.
- **Turn the switch off** to stop; all lights are left off.

The menubar's right-click menu also offers **Generate schedule now**, switch-daemon status, and a manual **Restart switch daemon**.

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
