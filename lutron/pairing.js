import fs from 'node:fs';
import { generateKeyPairSync } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { connectVerified, validateIdentity } from './security.js';

export function requestCertificate(connection, csr, timeoutMs = 90000) {
  return new Promise((resolve, reject) => {
    let requested = false;
    const finish = (error, result) => {
      clearTimeout(timer);
      connection.off('closed', closed);
      connection.off('message', message);
      if (error) reject(error); else resolve(result);
    };
    const closed = () => finish(new Error('Hub disconnected during pairing. Try again.'));
    const message = event => {
      if (!requested && event.Body?.Status?.Permissions?.includes('PhysicalAccess')) {
        requested = true;
        connection.socket.write(JSON.stringify({
          Header: { RequestType: 'Execute', Url: '/pair', ClientTag: 'pair' },
          Body: { CommandType: 'CSR', Parameters: {
            CSR: csr, DisplayName: 'Lights Menubar', DeviceUID: '000000000000', Role: 'Admin',
          } },
        }) + '\n');
      }
      if (!requested || event.Header?.ClientTag !== 'pair') return;
      const result = event.Body?.SigningResult;
      if (!/^2\d\d(?: |$)/.test(String(event.Header?.StatusCode)) ||
          typeof result?.Certificate !== 'string' || typeof result?.RootCertificate !== 'string') {
        finish(new Error('Hub rejected pairing. Press the button after starting pairing and try again.'));
      } else finish(null, result);
    };
    const timer = setTimeout(() => finish(new Error('Pairing timed out. Click Pair with hub and press its button within 90 seconds.')), timeoutMs);
    connection.on('closed', closed);
    connection.on('message', message);
    if (connection.socket.destroyed) closed();
  });
}

export async function pairHub(host, progress = () => {}) {
  progress('connecting');
  // Private key and CSR stay in memory; OpenSSL receives the key over a pipe.
  const { privateKey } = generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
  let csr;
  try {
    csr = execFileSync('/usr/bin/openssl', ['req', '-new', '-sha256', '-key', '/dev/stdin', '-subj', '/CN=lights-menubar'],
      { input: privateKey, encoding: 'utf8', timeout: 10000, stdio: ['pipe', 'pipe', 'pipe'] });
  } catch { throw new Error('Could not generate the pairing certificate request'); }
  const asset = name => fs.readFileSync(new URL(`./assets/${name}`, import.meta.url), 'utf8');
  let connection;
  try {
    connection = await connectVerified(host, 8083, {
      ca: asset('lap-ca.pem'), cert: asset('lap-client.pem'), key: asset('lap-client-key.pem'),
    });
    const signing = requestCertificate(connection, csr);
    progress('press_button');
    const result = await signing;
    progress('verifying');
    const identity = { key: privateKey, cert: result.Certificate, ca: result.RootCertificate };
    validateIdentity(identity);
    connection.socket.destroy();
    connection = await connectVerified(host, 8081, identity);
    const ping = await connection.request('ReadRequest', '/server/1/status/ping');
    if (!ping.Body?.PingResponse) throw new Error('Hub did not confirm the new pairing');
    return identity;
  } finally { connection?.socket.destroy(); }
}
