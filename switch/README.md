# switch — virtual HomeKit switch daemon

`index.js` publishes a virtual HomeKit switch (via [`hap-nodejs`](https://github.com/homebridge/HAP-NodeJS)).
Toggling it in the Home app writes `state.json`, which the menubar app watches to
turn the vacation schedule on/off.

In normal use you don't run this directly — the **menubar app bundles and supervises
it** as a child process (`menubar/Sources/LightsMenubar/SwitchDaemon.swift`). Running
`npm start` here is for development only, and will conflict on port 47129 if the app
is also running.

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
2. Note the **PIN**: shown in the menubar popover, and logged to `switch.log`.
3. Home app → **Add Accessory** → **More options…** → choose **Virtual Switch** →
   enter the PIN. (It has no QR code, so use "More options".)
4. Pairing keys are written to `persist/`. Done.

## Backup

`~/Library` is covered by Time Machine but **not** iCloud Drive. To move the pairing
to another Mac, copy `~/Library/Application Support/lights-virtual-switch/data/` there
before first launch (otherwise a fresh identity is generated).
