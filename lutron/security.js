import tls from 'node:tls';
import fs from 'node:fs';
import { X509Certificate, createPrivateKey, createPublicKey } from 'node:crypto';
import { once } from 'node:events';
import { Connection } from './protocol.js';

export function tlsOptions({ ca, key, cert }) {
  if (!ca || !key || !cert) throw new Error('Explicit CA and client identity required');
  return {
    ca, key, cert,
    minVersion: 'TLSv1.2',
    rejectUnauthorized: true,
    // Lutron certificates do not name the LAN IP/DNS hostname. Like HA's
    // pylutron-caseta, authenticate the chain against ONLY the supplied CA.
    checkServerIdentity: () => undefined,
  };
}

export async function connectVerified(host, port, identity, timeoutMs = 10000, onSocket = () => {}) {
  const socket = tls.connect({ host, port, ...tlsOptions(identity) });
  const connection = new Connection(socket);
  onSocket(socket);
  const timeout = setTimeout(() => socket.destroy(new Error('TLS connection timed out')), timeoutMs);
  try {
    await once(socket, 'secureConnect');
    if (!socket.authorized) throw new Error('Hub certificate was not authorized');
    return connection;
  } catch (error) {
    socket.destroy();
    throw error;
  } finally { clearTimeout(timeout); }
}

export function validateIdentity({ ca, key, cert }) {
  const root = new X509Certificate(ca);
  const client = new X509Certificate(cert);
  for (const certificate of [root, client]) {
    if (!(Date.parse(certificate.validFrom) <= Date.now() && Date.now() <= Date.parse(certificate.validTo))) {
      throw new Error('Certificate is expired or not yet valid');
    }
  }
  if (!root.ca || !root.verify(root.publicKey)) throw new Error('Invalid hub root CA');
  if (!client.checkIssued(root) || !client.verify(root.publicKey)) throw new Error('Client certificate is not signed by hub CA');
  const expected = createPublicKey(createPrivateKey(key)).export({ type: 'spki', format: 'der' });
  const actual = client.publicKey.export({ type: 'spki', format: 'der' });
  if (!expected.equals(actual)) throw new Error('Client certificate does not match generated private key');
}

export function loadPrivateJSON(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || (stat.mode & 0o077) !== 0 || stat.uid !== process.getuid()) {
      throw new Error('Credentials must be an owner-only regular file (chmod 600)');
    }
    return JSON.parse(fs.readFileSync(fd, 'utf8'));
  } finally { fs.closeSync(fd); }
}
