import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { requestCertificate } from '../pairing.js';

function fake() {
  const connection = new EventEmitter();
  connection.sent = [];
  connection.socket = { destroyed: false, write: data => connection.sent.push(JSON.parse(data)) };
  return connection;
}
const pressed = { Body: { Status: { Permissions: ['Public', 'PhysicalAccess'] } } };
test('pairing waits for physical access and sends only one CSR', async () => {
  const connection = fake();
  const waiting = requestCertificate(connection, 'test-csr');
  connection.emit('message', { Body: { Status: { Permissions: ['Public'] } } });
  assert.equal(connection.sent.length, 0);
  connection.emit('message', pressed);
  connection.emit('message', pressed);
  assert.equal(connection.sent.length, 1);
  assert.equal(connection.sent[0].Body.Parameters.CSR, 'test-csr');
  connection.emit('message', { Header: { ClientTag: 'pair', StatusCode: '200 OK' }, Body: { SigningResult: { Certificate: 'cert', RootCertificate: 'ca' } } });
  assert.deepEqual(await waiting, { Certificate: 'cert', RootCertificate: 'ca' });
  assert.equal(connection.listenerCount('message'), 0);
});
test('pairing timeout and disconnect clean up listeners', async () => {
  const timed = fake();
  await assert.rejects(requestCertificate(timed, 'csr', 5), /timed out/);
  assert.equal(timed.listenerCount('message'), 0);
  const disconnected = fake();
  const pending = requestCertificate(disconnected, 'csr');
  disconnected.emit('closed');
  await assert.rejects(pending, /disconnected/);
  assert.equal(disconnected.listenerCount('message'), 0);
});
test('pairing rejects error responses and ignores unsolicited signing results', async () => {
  const connection = fake();
  const pending = requestCertificate(connection, 'csr');
  connection.emit('message', { Header: { ClientTag: 'pair', StatusCode: '200 OK' }, Body: { SigningResult: { Certificate: 'cert', RootCertificate: 'ca' } } });
  assert.equal(connection.listenerCount('message'), 1);
  connection.emit('message', pressed);
  connection.emit('message', { Header: { ClientTag: 'pair', StatusCode: '401 Unauthorized' } });
  await assert.rejects(pending, /rejected/);
});
