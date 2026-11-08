import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { once } from 'node:events';
import { execFileSync } from 'node:child_process';
import { connectVerified, validateIdentity } from '../security.js';

test('real TLS verifies explicit CA, client auth, expiry and rejects rogue certificates', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lights-tls-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const openssl = (...args) => execFileSync('/usr/bin/openssl', args, { cwd: dir, stdio: 'pipe' });
  const read = name => fs.readFileSync(path.join(dir, name), 'utf8');
  fs.writeFileSync(path.join(dir, 'ca.cnf'), '[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=Test Root\n[ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n');
  for (const root of ['root', 'rogue']) {
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1',
      '-keyout', `${root}.key`, '-out', `${root}.pem`, '-config', 'ca.cnf');
  }
  openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'leaf.key', '-out', 'leaf.csr', '-subj', '/CN=Lutron-style-non-DNS-identity');
  fs.writeFileSync(path.join(dir, 'leaf.ext'), 'basicConstraints=CA:false\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n');
  openssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-set_serial', '2',
    '-days', '1', '-sha256', '-extfile', 'leaf.ext', '-out', 'leaf.pem');
  fs.writeFileSync(path.join(dir, 'index'), '');
  fs.writeFileSync(path.join(dir, 'serial'), '03\n');
  fs.writeFileSync(path.join(dir, 'sign.cnf'), '[ca]\ndefault_ca=local\n[local]\ndatabase=index\nserial=serial\nnew_certs_dir=.\ncertificate=root.pem\nprivate_key=root.key\ndefault_md=sha256\npolicy=policy\n[policy]\ncommonName=supplied\n');
  openssl('ca', '-batch', '-config', 'sign.cnf', '-in', 'leaf.csr', '-out', 'expired.pem',
    '-startdate', '20000101000000Z', '-enddate', '20010101000000Z', '-extfile', 'leaf.ext');
  const identity = { ca: read('root.pem'), cert: read('leaf.pem'), key: read('leaf.key') };
  validateIdentity(identity);
  assert.throws(() => validateIdentity({ ...identity, key: read('rogue.key') }), /does not match/);
  assert.throws(() => validateIdentity({ ...identity, ca: read('rogue.pem') }), /not signed/);
  assert.throws(() => validateIdentity({ ...identity, cert: read('expired.pem') }), /expired/);

  async function server(cert, run) {
    const sockets = new Set();
    const srv = tls.createServer({ key: identity.key, cert, ca: identity.ca, requestCert: true, rejectUnauthorized: true }, socket => {
      sockets.add(socket);
      socket.on('error', () => {});
      socket.on('close', () => sockets.delete(socket));
    });
    srv.on('tlsClientError', () => {});
    srv.listen(0, '127.0.0.1');
    await once(srv, 'listening');
    try { await run(srv.address().port); }
    finally { for (const socket of sockets) socket.destroy(); await new Promise(resolve => srv.close(resolve)); }
  }
  await server(identity.cert, async port => {
    const connection = await connectVerified('127.0.0.1', port, identity);
    assert.equal(connection.socket.authorized, true);
    connection.socket.destroy();
    await assert.rejects(connectVerified('127.0.0.1', port, { ...identity, ca: read('rogue.pem') }));
  });
  await server(read('expired.pem'), async port => {
    await assert.rejects(connectVerified('127.0.0.1', port, identity), /expired/i);
  });
});
