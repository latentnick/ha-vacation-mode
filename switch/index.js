import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Accessory, Characteristic, CharacteristicEventTypes, HAPStorage, Service, uuid } from "hap-nodejs";

const APP_DIR = path.join(os.homedir(), "Library", "Application Support", "lights-virtual-switch");
const PAIRING_DIR = path.join(APP_DIR, "data"); // HAP credentials + pairing keys
const LOG_DIR = path.join(os.homedir(), "Library", "Logs", "lights-virtual-switch");
fs.mkdirSync(APP_DIR, { recursive: true });
fs.mkdirSync(path.join(PAIRING_DIR, "persist"), { recursive: true });
fs.mkdirSync(LOG_DIR, { recursive: true });

const LOG_FILE = path.join(LOG_DIR, "switch.log");
const STATE_FILE = path.join(APP_DIR, "state.json");
const STATE_TMP = STATE_FILE + ".tmp";
const CREDENTIALS_FILE = path.join(PAIRING_DIR, "credentials.json");

function log(message) {
  const line = `${new Date().toISOString()}  ${message}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + "\n");
}

// HAP rejects these trivial setup codes; regenerate if we happen to land on one.
const INVALID_PINCODES = new Set([
  "000-00-000", "111-11-111", "222-22-222", "333-33-333", "444-44-444",
  "555-55-555", "666-66-666", "777-77-777", "888-88-888", "999-99-999",
  "123-45-678", "876-54-321",
]);

function randomUsername() {
  // Stable MAC-style accessory identity, e.g. "AB:CD:EF:12:34:56".
  return Array.from(crypto.randomBytes(6), (b) => b.toString(16).padStart(2, "0").toUpperCase()).join(":");
}

function randomPincode() {
  let code;
  do {
    const d = Array.from({ length: 8 }, () => crypto.randomInt(10).toString());
    code = `${d[0]}${d[1]}${d[2]}-${d[3]}${d[4]}-${d[5]}${d[6]}${d[7]}`;
  } while (INVALID_PINCODES.has(code));
  return code;
}

// Credentials (username + pincode) must exist before publishing. On first run we
// generate a fresh identity + setup code and persist it atomically; subsequent
// runs reuse it so the HomeKit pairing stays valid.
function loadOrCreateCredentials() {
  if (fs.existsSync(CREDENTIALS_FILE)) {
    return JSON.parse(fs.readFileSync(CREDENTIALS_FILE, "utf8"));
  }
  const credentials = { username: randomUsername(), pincode: randomPincode() };
  const tmp = CREDENTIALS_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(credentials, null, 2));
  fs.renameSync(tmp, CREDENTIALS_FILE);
  log(`Generated new HAP credentials (username ${credentials.username})`);
  return credentials;
}

const credentials = loadOrCreateCredentials();

HAPStorage.setCustomStoragePath(path.join(PAIRING_DIR, "persist"));

function writeState(on) {
  const payload = JSON.stringify({ on, updated: new Date().toISOString() });
  fs.writeFileSync(STATE_TMP, payload);
  fs.renameSync(STATE_TMP, STATE_FILE);
}

let on = false;
writeState(on);

const switchUUID = uuid.generate("hap-nodejs:virtual-switch");
const accessory = new Accessory("Virtual Switch", switchUUID);

const switchService = new Service.Switch("Virtual Switch");

switchService
  .getCharacteristic(Characteristic.On)
  .on(CharacteristicEventTypes.GET, (callback) => {
    callback(null, on);
  })
  .on(CharacteristicEventTypes.SET, (value, callback) => {
    on = value;
    log(on ? "ON" : "OFF");
    writeState(on);
    callback();
  });

accessory.addService(switchService);

accessory.publish({
  username: credentials.username,
  pincode: credentials.pincode,
  port: 47129,
  category: 8, // SWITCH
});

log(`Virtual Switch published — pair it in Home app with pin ${credentials.pincode}`);

process.on("SIGINT", () => {
  log("Shutting down");
  process.exit(0);
});
