// Bounded operations, or a monitor supervised through its parent stdin pipe.
// Credentials arrive over stdin, never argv.
import { connectVerified, validateIdentity } from './security.js';
import { setAndVerify } from './control.js';
import { pairHub } from './pairing.js';
import { monitor } from './monitor.js';

let connection;
let deadline = setTimeout(() => { process.stderr.write('Lutron operation timed out\n'); process.exit(1); }, 30000);
try {
  const input = await new Promise((resolve, reject) => {
    let buffer = '';
    process.stdin.setEncoding('utf8');
    const cleanup = () => { process.stdin.off('data', data); process.stdin.off('end', end); };
    const end = () => { cleanup(); resolve(buffer); };
    const data = chunk => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 65536) { cleanup(); reject(new Error('Input too large')); }
      else if (buffer.includes('\n')) { cleanup(); resolve(buffer.slice(0, buffer.indexOf('\n'))); }
    };
    process.stdin.on('data', data);
    process.stdin.on('end', end);
  });
  const { command, host, identity, zone, action, zones } = JSON.parse(input);
  if (!['pair', 'discover', 'set', 'monitor'].includes(command) || typeof host !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9.:-]*$/.test(host)) throw new Error('Invalid Lutron operation');
  if (command === 'monitor') {
    // Keep stdin open as the parent's liveness pipe. EOF also covers app crashes.
    process.stdin.once('end', () => process.exit(0));
    if (process.stdin.readableEnded) throw new Error('Monitor requires a live parent');
  }
  if (command === 'pair') {
    clearTimeout(deadline);
    deadline = setTimeout(() => { process.stderr.write('Pairing timed out. Please try again.\n'); process.exit(1); }, 120000);
    const paired = await pairHub(host, progress => process.stdout.write(JSON.stringify({ progress }) + '\n'));
    // Only the parent process reads this pipe. Never log this result.
    process.stdout.write(JSON.stringify({ identity: paired }) + '\n');
  } else {
    validateIdentity(identity);
    connection = await connectVerified(host, 8081, identity);
    if (command === 'monitor') {
      clearTimeout(deadline);
      await monitor(connection, zones, event => process.stdout.write(JSON.stringify(event) + '\n'));
    } else if (command === 'discover') {
      const response = await connection.request('ReadRequest', '/device');
      const devices = (response.Body?.Devices ?? []).filter(d => d.DeviceType === 'DivaSmartSwitch')
        .flatMap(d => (d.LocalZones ?? []).map(z => ({ zone: z.href, name: (d.FullyQualifiedName ?? [d.Name]).join(' / ') })));
      if (!devices.length || devices.some(d => !/^\/zone\/[1-9]\d*$/.test(d.zone) || typeof d.name !== 'string')) throw new Error('No supported switches in hub inventory');
      process.stdout.write(JSON.stringify({ devices }) + '\n');
    } else {
      const state = await setAndVerify(connection, zone, action);
      process.stdout.write(JSON.stringify({ verified: true, ...state }) + '\n');
    }
  }
} catch (error) {
  // Do not echo untrusted responses or stdin, which contains private key material.
  const safe = error instanceof SyntaxError ? 'Invalid helper JSON' : error.message;
  process.stderr.write(safe + '\n');
  process.exitCode = 1;
} finally {
  connection?.socket.destroy();
  clearTimeout(deadline);
  process.stdin.destroy();
}
