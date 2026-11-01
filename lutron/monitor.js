import { once } from 'node:events';
import { zoneStates } from './protocol.js';

// One session; the parent supervises reconnects and treats each session as new
// coverage. Full snapshots serve as heartbeats even when no light changes.
export async function monitor(connection, zones, emit) {
  if (!Array.isArray(zones) || !zones.length || zones.some(z => !/^\/zone\/[1-9]\d*$/.test(z)) || new Set(zones).size !== zones.length) throw new Error('Invalid monitor zones');
  const closed = once(connection, 'closed');
  const inventory = await connection.request('ReadRequest', '/device');
  const supported = new Set((inventory.Body?.Devices ?? []).filter(d => d.DeviceType === 'DivaSmartSwitch').flatMap(d => d.LocalZones ?? []).map(z => z.href));
  if (zones.some(z => !supported.has(z))) throw new Error('A configured switch is missing from the hub');
  const send = event => emit({ ...event, time: Date.now() / 1000 });
  const latest = new Map();
  const changed = response => {
    for (const state of zoneStates(response)) if (zones.includes(state.zone)) {
      latest.set(state.zone, state);
      send({ kind: 'state', ...state });
    }
  };
  connection.on('message', changed);
  let timer;
  const sample = async () => {
    for (const zone of zones) {
      const response = await connection.request('ReadRequest', `${zone}/status`);
      const state = zoneStates(response).find(s => s.zone === zone);
      if (!state) throw new Error('Hub did not report a switch state');
    }
    // An unsolicited update may arrive while other zones are being queried.
    // Use the latest observed state rather than overwriting it with an older read.
    send({ kind: 'sample', states: zones.map(zone => latest.get(zone)) });
  };
  const poll = () => {
    timer = setTimeout(async () => {
      try { await sample(); if (!connection.socket.destroyed) poll(); }
      catch (error) { connection.socket.destroy(error); }
    }, 15000);
  };
  try {
    await sample();
    poll();
    await closed;
    throw connection.failure ?? new Error('Lutron monitor disconnected');
  } finally {
    clearTimeout(timer);
    connection.off('message', changed);
  }
}
