import test from 'node:test';
import assert from 'node:assert/strict';
import { setAndVerify } from '../control.js';

function fake(type = 'DivaSmartSwitch', follows = true) {
  let level = 100;
  return {
    commands: [],
    async request(_, url) {
      if (url === '/device') return { Body: { Devices: [{ DeviceType: type, Name: 'Office', LocalZones: [{ href: '/zone/2' }] }] } };
      return { Body: { ZoneStatus: { Zone: { href: '/zone/2' }, Level: level } } };
    },
    async setSwitch(zone, on) { this.commands.push({ zone, on }); if (follows) level = on ? 100 : 0; },
  };
}
test('control sends one explicit command and verifies observed state', async () => {
  const connection = fake();
  const events = [];
  await setAndVerify(connection, '/zone/2', 'off', event => events.push(event));
  assert.deepEqual(connection.commands, [{ zone: '/zone/2', on: false }]);
  assert.deepEqual(events.map(e => e.kind), ['before', 'accepted', 'verified']);
});
test('control rejects unknown zones, non-switches and invalid actions before writes', async () => {
  for (const [connection, zone, action] of [[fake(), '/zone/9', 'on'], [fake('Shade'), '/zone/2', 'on'], [fake(), '/zone/2', 'toggle']]) {
    await assert.rejects(setAndVerify(connection, zone, action));
    assert.equal(connection.commands.length, 0);
  }
});
test('acceptance without observed state change fails without repeating command', async () => {
  const connection = fake('DivaSmartSwitch', false);
  await assert.rejects(setAndVerify(connection, '/zone/2', 'off', () => {}, 1), /not observed/);
  assert.equal(connection.commands.length, 1);
});
