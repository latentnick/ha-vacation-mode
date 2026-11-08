import test from 'node:test';
import assert from 'node:assert/strict';
import { PassThrough } from 'node:stream';
import { Connection, Frames, zoneStates } from '../protocol.js';

test('TLS framing handles fragmented, combined and CRLF messages', () => {
  const frames = new Frames();
  assert.deepEqual(frames.push('{"Header":'), []);
  assert.deepEqual(frames.push('{}}\r\n{"Header":{},"Body":2}\n{"Header"'), [{ Header: {} }, { Header: {}, Body: 2 }]);
  assert.deepEqual(frames.push(':{}}\n'), [{ Header: {} }]);
});
test('invalid JSON, invalid envelopes and oversized frames fail closed', () => {
  for (const input of ['null\n', '[]\n', '{}\n', 'not json\n', 'x'.repeat(4 * 1024 * 1024 + 1)]) {
    assert.throws(() => new Frames().push(input));
  }
});
test('correlates replies and rejects errors without losing unsolicited messages', async () => {
  const socket = new PassThrough();
  let sent;
  socket.write = data => { sent = JSON.parse(data); return true; };
  const connection = new Connection(socket);
  const messages = [];
  connection.on('message', message => messages.push(message));
  const pending = connection.request('ReadRequest', '/device');
  socket.emit('data', JSON.stringify({ Header: { StatusCode: '200 OK' }, Body: {} }) + '\n');
  assert.equal(connection.pending.size, 1);
  socket.emit('data', JSON.stringify({ Header: { ClientTag: sent.Header.ClientTag, StatusCode: '403 Forbidden' } }) + '\n');
  await assert.rejects(pending, /403/);
  assert.equal(messages.length, 2);
  assert.equal(connection.pending.size, 0);
  socket.destroy();
});
test('unknown levels never become off; dimmed lights count as on', () => {
  assert.deepEqual(zoneStates({ Body: { ZoneStatuses: [
    { Zone: { href: '/zone/1' }, Level: 0 },
    { Zone: { href: '/zone/2' }, Level: 12 },
    { Zone: { href: '/zone/3' }, Level: -1 },
    { Zone: { href: '/zone/4' } },
  ] } }), [{ zone: '/zone/1', level: 0, on: false }, { zone: '/zone/2', level: 12, on: true }]);
});
test('connection rejects control commands', () => {
  const socket = new PassThrough();
  const connection = new Connection(socket);
  assert.throws(() => connection.request('CreateRequest', '/zone/1/commandprocessor'), /Read-only/);
  socket.destroy();
});
test('disconnect rejects in-flight reads instead of reporting success', async () => {
  const socket = new PassThrough();
  // Prevent the fake socket from looping our request back as a response.
  socket.write = () => true;
  const connection = new Connection(socket);
  const result = connection.request('ReadRequest', '/device');
  socket.destroy();
  await assert.rejects(result, /Disconnected/);
  assert.equal(connection.pending.size, 0);
});
