# Local Caséta LEAP client

Standalone monitoring/control prototype with **no npm dependencies** or imported third-party
JavaScript. Requires Node 22+ and macOS utilities `/usr/bin/dns-sd` and
`/usr/bin/openssl`. No install step. Existing app behavior is unchanged.

```sh
node cli.js discover
node cli.js probe 192.168.86.61
node cli.js pair 192.168.86.61
node cli.js watch 192.168.86.61
```

Discovery browses Bonjour for ten seconds. Resolve a result with
`dns-sd -L 'Lutron Status' _lutron._tcp local.` and then
`dns-sd -G v4v6 Lutron-06865523.local.` (Ctrl-C stops these commands).
Probe verifies the pairing endpoint without pairing. Pair waits up to 90 seconds
for the small button on the back of the hub. Watch records until Ctrl-C.
Use the same host for pairing/watching and one process per host.

## Certificate trust

- Pairing on port 8083 verifies the hub against the explicit Lutron LAP CA.
- A physical button press authorizes a CSR for a new RSA-2048/SHA-256 identity.
- Check the returned CA, dates, certificate signature and private-key match.
- Verify a mutual-TLS connection and LEAP ping on port 8081 before atomically
  saving credentials. Never overwrite an existing pairing.
- Every monitoring connection verifies against the saved hub-specific CA.

Both endpoints require TLS 1.2+ and certificate-chain verification. There is no
system-CA or insecure fallback. As in Home Assistant's pylutron-caseta, DNS hostname
matching is disabled: Lutron certificate identities do not match LAN addresses.
Bootstrap authenticates against the Lutron CA rather than a unique hub fingerprint;
physical access selects the hub being paired. Bonjour alone is not authentication.

Only three static upstream PEM assets are retained. See
[provenance, hashes and licensing](../lutron/assets/PROVENANCE.md). The public association key
is not a user's private paired key. No upstream protocol code runs. This is a
source-informed implementation, not a formal clean-room implementation.

Private credentials and logs live under gitignored `.local/<host>/`, with owner-only
directories (0700) and new files (0600). Credential loading rejects symlinks and
insecure permissions. Keys are files, not Keychain entries yet. Pairing failure
cleans temporary keys; force-killing the process can leave a private temporary folder.

## Protocol and monitoring

The local transport handles bounded newline-delimited JSON, request tags, timeouts,
error responses, unsolicited messages and disconnect cleanup. Its generic request API only
allows ReadRequest and SubscribeRequest. The separate setSwitch method permits only
GoToLevel 0 or 100. The set CLI validates the zone against discovered DivaSmartSwitch
devices, reads initial state, sends one command, then reads back to verify. It does
not retry commands automatically. Watch remains read-only.

The monitor reads device inventory, snapshots every local zone, listens for Caséta
unsolicited state reports and reconciles with reads every 30 seconds. Reconnection
uses bounded backoff and starts fresh snapshots. JSONL records include:

- inventory: device names/types and zone identifiers.
- snapshot/change: first observed level per connection and subsequent changes.
- connected/disconnected/error/stopped: coverage and lifecycle markers.

Levels above zero count as on; unknown states are omitted. Times are UTC receive
times. Polling recovers final state, not missed transitions. Physical presses and
other apps' commands cannot be distinguished. Inventory may include shades/fans;
select lighting zones before importing history. Disconnect detection may lag until
the next failed read. This is diagnostic JSONL, not an Influx replacement; there is
no log rotation or background service yet.

## Validation

Run `npm test`. Tests use ephemeral local TLS certificates and loopback servers:
valid mutual TLS, wrong CA, expired certificates, mismatched keys, credential
permissions, fragmented/malformed frames, response errors and disconnect cleanup.
Socket tests require permission to bind a loopback port.

On 2026-11-01, the new probe successfully verified 192.168.86.61 against the LAP CA
without pairing. Subsequent hardware testing completed verified pairing, live Office
on/off reports from both the physical switch and the Home/Lutron app, and a process
restart using saved credentials with fresh snapshots of all four zones. Automatic
recovery from a network outage remains untested. This is not a comprehensive
security audit. Before migration, compare with HA, import existing Influx history,
and exclude gaps and vacation playback from training data.

## Language choice

Node's built-in TLS and crypto keep the implementation small and avoid new packages;
the app already bundles Node. Swift could eventually integrate directly using
Network.framework/Security.framework and Keychain, but adds identity-import and CSR
work. Rust adds a new build target and TLS/X.509 crates. A language change alone does
not establish correct certificate verification.

## Direct control

```sh
node cli.js set 192.168.86.61 /zone/2 off
node cli.js set 192.168.86.61 /zone/2 on
```

Zone 2 is Office / Main Lights on the tested hub. On 2026-11-01, both commands
were accepted and independently verified via status reads; the Office lights were
restored to their initial on state. This test bypassed Home Assistant. The monitor
was stopped beforehand. Control is limited to the DivaSmartSwitch device type.

The protocol, security and control modules now live in `../lutron/` and are shared
with the real menubar app. This CLI remains the pairing/diagnostic tool. The app
imports its credentials into Keychain and does not use the prototype data folder
after import.
