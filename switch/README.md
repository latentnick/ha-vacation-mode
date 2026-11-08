# switch — virtual HomeKit switch daemon

`index.js` publishes a virtual HomeKit switch (via [`hap-nodejs`](https://github.com/homebridge/HAP-NodeJS)).
Toggling it in the Home app writes `state.json`, which the menubar app watches to
arm/disarm the vacation schedule. The daemon does not generate schedules or
control physical lights: the Swift app reads SQLite history and executes the
schedule through its separate Lutron LEAP helper.

In normal use you don't run this directly — the **menubar app bundles and supervises
it** as a child process (`menubar/Sources/LightsMenubar/SwitchDaemon.swift`). Running
`npm start` here is for development only, and will conflict on port 47129 if the app
is also running.

## Process and state lifecycle

`SwitchDaemon.swift` launches Node with `LIGHTS_SUPERVISED=1` and an open stdin
pipe. The daemon shuts down on SIGINT, SIGTERM, or stdin closure, including when
the parent app crashes. The supervisor retries unexpected exits with capped
backoff and stops after six consecutive rapid failures.

On startup, `state.js` restores the saved `on` value. Missing or malformed JSON
defaults to off; other read failures abort startup instead of overwriting state.
Each update atomically replaces `state.json` with `{ "on": true/false, "updated":
"<ISO timestamp>" }`. The app watches replacements and distinguishes on, off, and
unreadable/unknown state. Restarting the daemon preserves a valid armed state.

## State & pairing data

Everything the daemon persists lives under Application Support (a real directory, not
a symlink — keeping it out of `~/Documents` avoids the macOS Documents-access prompt):

```
~/Library/Application Support/lights-virtual-switch/
  state.json                 runtime on/off state (watched by the menubar app)
  data/
    credentials.json         { "username": <MAC-style id>, "pincode": <setup code> }
    persist/
      AccessoryInfo.<MAC>.json   long-term pairing keys per controller
      IdentifierCache.<MAC>.json IID assignments
~/Library/Logs/lights-virtual-switch/
  switch.log                 daemon's own ON/OFF + lifecycle log
  daemon.out.log             raw node stdout/stderr (crash safety net)
```

`credentials.json` is **auto-generated on first run** (random username + a valid
random setup code) if it doesn't exist. Losing it means a new identity and re-pairing.
Losing `persist/` makes the Home app show the accessory as unresponsive (remove + re-add).

## Pairing

1. Start the menubar app (or `npm start` here). The daemon publishes the accessory.
2. Note the **PIN**: shown in the menubar popover and stored in `data/credentials.json`.
3. Home app → **Add Accessory** → **More options…** → choose **Virtual Switch** →
   enter the PIN. (It has no QR code, so use "More options".)
4. Pairing keys are written to `persist/`. Done.

## Backup

`~/Library` is covered by Time Machine but **not** iCloud Drive. To move the pairing
to another Mac, copy `~/Library/Application Support/lights-virtual-switch/data/` there
before first launch (otherwise a fresh identity is generated).

## Development

From this directory, install dependencies with `npm install` and run `npm start`.
Run state-restoration tests with `npm test`. To use the daemon from an unbundled
Swift app, set `LIGHTS_NODE_BIN` to an absolute Node executable and
`LIGHTS_SWITCH_DIR` to this directory. Use only one daemon at a time: development
and bundled runs share the same port, state, and pairing files.
