import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { monitor } from '../lutron/monitor.js';

test('full heartbeat retains an unsolicited update received during other zone reads', async () => {
  const connection = new EventEmitter();
  connection.socket = { destroyed: false };
  const response = (zone, level) => ({ Body: { ZoneStatus: { Zone: { href: zone }, Level: level } } });
  connection.request = async (_, url) => {
    if (url === '/device') return { Body: { Devices: [{ DeviceType: 'DivaSmartSwitch', LocalZones: [{ href: '/zone/2' }, { href: '/zone/3' }] }] } };
    const zone = url.replace('/status', '');
    if (zone === '/zone/3') connection.emit('message', response('/zone/2', 100));
    const result = response(zone, 0);
    connection.emit('message', result);
    return result;
  };
  const samples = [];
  await assert.rejects(monitor(connection, ['/zone/2', '/zone/3'], event => {
    if (event.kind === 'sample') { samples.push(event); connection.emit('closed'); }
  }), /disconnected/);
  assert.equal(samples.length, 1);
  assert.equal(samples[0].states.find(s => s.zone === '/zone/2').on, true);
  assert.equal(connection.listenerCount('message'), 0);
});

test('monitor refuses missing or unsupported selected zones', async () => {
  const connection = new EventEmitter();
  connection.request = async () => ({ Body: { Devices: [] } });
  await assert.rejects(monitor(connection, ['/zone/2'], () => assert.fail('No samples expected')), /missing/);
  await assert.rejects(monitor(connection, [], () => {}), /Invalid/);
});
