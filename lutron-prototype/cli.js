import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { zoneStates } from '../lutron/protocol.js';
import { connectVerified, validateIdentity, loadPrivateJSON } from '../lutron/security.js';
import { setAndVerify } from '../lutron/control.js';

process.umask(0o077);
const [command, host] = process.argv.slice(2);
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '.local');
const asset = name => fs.readFileSync(new URL(`../lutron/assets/${name}`, import.meta.url), 'utf8');
const bootstrapIdentity = () => ({ ca: asset('lap-ca.pem'), cert: asset('lap-client.pem'), key: asset('lap-client-key.pem') });
let stopping = false;
let active;
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  stopping = true;
  active?.destroy();
});

async function open(port, identity) {
  return connectVerified(host, port, identity, 10000, socket => { active = socket; });
}

async function pair(directory) {
  const target = path.join(directory, 'credentials.json');
  if (fs.existsSync(target)) throw new Error('Already paired. Use watch or a different host.');
  const temporary = fs.mkdtempSync(path.join(directory, 'pair-'));
  const keyPath = path.join(temporary, 'pending.key');
  try {
    const csr = execFileSync('/usr/bin/openssl', ['req', '-new', '-newkey', 'rsa:2048', '-sha256', '-nodes',
      '-keyout', keyPath, '-subj', '/CN=lights-monitor'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    const connection = await open(8083, bootstrapIdentity());
    console.error('Press the small button on the back of the Lutron hub now. Waiting up to 90 seconds…');
    const identity = await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Pairing timed out; run pair again when near the hub.')), 90000);
      let requested = false;
      connection.once('closed', () => { clearTimeout(timer); reject(new Error('Pairing connection closed')); });
      connection.on('message', message => {
        if (!requested && message.Body?.Status?.Permissions?.includes('PhysicalAccess')) {
          requested = true;
          connection.socket.write(JSON.stringify({ Header: { RequestType: 'Execute', Url: '/pair', ClientTag: 'pair' },
            Body: { CommandType: 'CSR', Parameters: { CSR: csr, DisplayName: 'lights-monitor', DeviceUID: '000000000000', Role: 'Admin' } } }) + '\n');
        }
        if (message.Header?.ClientTag !== 'pair') return;
        clearTimeout(timer);
        const result = message.Body?.SigningResult;
        if (!String(message.Header?.StatusCode).startsWith('2') || !result?.Certificate || !result?.RootCertificate) return reject(new Error(`Pairing failed: ${message.Header?.StatusCode}`));
        try {
          const identity = { host, key: fs.readFileSync(keyPath, 'utf8'), cert: result.Certificate, ca: result.RootCertificate };
          validateIdentity(identity);
          resolve(identity);
        } catch (error) { reject(error); }
      });
    });
    connection.socket.destroy();
    const verified = await open(8081, identity);
    const ping = await verified.request('ReadRequest', '/server/1/status/ping');
    if (!ping.Body?.PingResponse) throw new Error('Hub did not return a valid LEAP ping');
    // Publish atomically without replacing an existing pairing.
    const pending = path.join(temporary, 'credentials.json');
    fs.writeFileSync(pending, JSON.stringify(identity), { flag: 'wx', mode: 0o600 });
    fs.linkSync(pending, target);
    console.error('Paired. Credentials saved privately. Run watch to begin recording.');
  } finally {
    active?.destroy();
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

async function watch(directory) {
  const credentials = loadPrivateJSON(path.join(directory, 'credentials.json'));
  validateIdentity(credentials);
  const output = path.join(directory, 'observations.jsonl');
  const record = (kind, data = {}) => {
    const line = JSON.stringify({ time: new Date().toISOString(), host, kind, ...data });
    fs.appendFileSync(output, line + '\n', { mode: 0o600 });
    console.log(line);
  };
  console.error(`Recording to ${output}. Ctrl-C stops. No light commands are sent.`);
  let attempt = 0;
  while (!stopping) {
    let heartbeat;
    try {
      const connection = await open(8081, credentials);
      // The hub certificate has a Lutron identity rather than a DNS hostname;
      // verify its chain against the hub-specific CA obtained during pairing.
      const closed = once(connection, 'closed');
      record('connected');
      const levels = new Map();
      connection.on('message', message => {
        for (const state of zoneStates(message)) {
          if (levels.get(state.zone) === state.level) continue;
          const kind = levels.has(state.zone) ? 'change' : 'snapshot';
          levels.set(state.zone, state.level);
          record(kind, state);
        }
      });
      const devices = await connection.request('ReadRequest', '/device');
      record('inventory', { devices: devices.Body?.Devices ?? [] });
      // Caséta reports unsolicited zone changes. Reading each zone establishes
      // initial state; periodic reads also reconcile missing notifications.
      const zones = [...new Set((devices.Body?.Devices ?? []).flatMap(d => d.LocalZones ?? []).map(z => z.href))];
      if (!zones.length) throw new Error('No zones found in hub inventory');
      const refresh = async () => {
        for (const zone of zones) await connection.request('ReadRequest', `${zone}/status`);
      };
      await refresh();
      attempt = 0;
      const poll = () => {
        heartbeat = setTimeout(async () => {
          try {
            await refresh();
            if (!connection.socket.destroyed) poll();
          } catch (error) { connection.socket.destroy(error); }
        }, 30000);
      };
      poll();
      await closed;
      if (connection.failure) throw connection.failure;
    } catch (error) {
      if (!stopping) record('error', { message: error.message });
    } finally {
      clearInterval(heartbeat);
      active?.destroy();
      record(stopping ? 'stopped' : 'disconnected');
    }
    const waitSeconds = Math.min(30, 2 ** Math.min(attempt++, 5));
    for (let i = 0; i < waitSeconds && !stopping; i++) await delay(1000);
  }
}

try {
  if (command === 'discover') {
    const browser = spawn('/usr/bin/dns-sd', ['-B', '_lutron._tcp', 'local.'], { stdio: 'inherit' });
    active = { destroy: () => browser.kill() };
    browser.on('error', error => { console.error(error.message); process.exitCode = 1; });
    browser.on('exit', code => { if (code) process.exitCode = 1; });
    try { for (let i = 0; i < 10 && !stopping; i++) await delay(1000); }
    finally { browser.kill(); }
  } else if (['probe', 'pair', 'watch', 'set'].includes(command) && host && /^[a-zA-Z0-9][a-zA-Z0-9.:-]*$/.test(host)) {
    const directory = path.join(root, host.replaceAll(':', '_'));
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || (stat.mode & 0o077) || stat.uid !== process.getuid()) throw new Error('Data directory must be owner-only (chmod 700), not a symlink');
    if (command === 'probe') {
      const connection = await open(8083, bootstrapIdentity());
      console.log(JSON.stringify({ host, authorized: connection.socket.authorized,
        fingerprint: connection.socket.getPeerCertificate().fingerprint256,
        subject: connection.socket.getPeerCertificate().subject }));
      connection.socket.destroy();
    } else if (command === 'set') {
      const credentials = loadPrivateJSON(path.join(directory, 'credentials.json'));
      validateIdentity(credentials);
      const connection = await open(8081, credentials);
      try {
        await setAndVerify(connection, process.argv[4], process.argv[5], event => console.log(JSON.stringify(event)));
      } finally { connection.socket.destroy(); }
    } else if (command === 'pair') await pair(directory);
    else await watch(directory);
  } else {
    console.log('Usage: node cli.js discover | probe <host> | pair <host> | watch <host> | set <host> /zone/<id> on|off');
    if (command && command !== '--help') process.exitCode = 1;
  }
} catch (error) {
  console.error(error.code === 'ENOENT' && command === 'watch' ? 'No credentials found. Run pair with this same host first.' : error.message);
  active?.destroy();
  process.exitCode = 1;
}
