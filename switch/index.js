import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Accessory, Characteristic, CharacteristicEventTypes, HAPStorage, Service, uuid } from "hap-nodejs";

const APP_DIR = path.join(os.homedir(), "Library", "Application Support", "lights-virtual-switch");
const PAIRING_DIR = path.join(APP_DIR, "data"); // symlink to ~/Documents/home/lights-pairing
const LOG_DIR = path.join(os.homedir(), "Library", "Logs", "lights-virtual-switch");
fs.mkdirSync(APP_DIR, { recursive: true });
fs.mkdirSync(LOG_DIR, { recursive: true });

const LOG_FILE = path.join(LOG_DIR, "switch.log");
const STATE_FILE = path.join(APP_DIR, "state.json");
const STATE_TMP = STATE_FILE + ".tmp";
const CREDENTIALS_FILE = path.join(PAIRING_DIR, "credentials.json");

const credentials = JSON.parse(fs.readFileSync(CREDENTIALS_FILE, "utf8"));

HAPStorage.setCustomStoragePath(path.join(PAIRING_DIR, "persist"));

function log(message) {
  const line = `${new Date().toISOString()}  ${message}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + "\n");
}

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
