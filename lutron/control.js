import { setTimeout as delay } from 'node:timers/promises';
import { zoneStates } from './protocol.js';

export async function setAndVerify(connection, zone, action, report = () => {}, attempts = 10) {
  if (!/^\/zone\/[1-9]\d*$/.test(zone) || !['on', 'off'].includes(action)) throw new Error('Expected /zone/<number> and on|off');
  const inventory = await connection.request('ReadRequest', '/device');
  const device = inventory.Body?.Devices?.find(d => d.LocalZones?.some(z => z.href === zone));
  // Deliberately limited to the exact switch type verified in this home.
  if (device?.DeviceType !== 'DivaSmartSwitch') throw new Error('Zone is not a discovered DivaSmartSwitch');
  const name = (device.FullyQualifiedName ?? [device.Name]).join(' / ');
  const read = async () => zoneStates(await connection.request('ReadRequest', `${zone}/status`)).find(s => s.zone === zone);
  const before = await read();
  if (!before) throw new Error('Cannot determine initial state; no command sent');
  report({ kind: 'before', name, ...before });
  await connection.setSwitch(zone, action === 'on');
  report({ kind: 'accepted', name, zone, action });
  for (let i = 0; i < attempts; i++) {
    const after = await read();
    if (after?.on === (action === 'on')) {
      report({ kind: 'verified', name, ...after });
      return after;
    }
    if (i + 1 < attempts) await delay(500);
  }
  throw new Error('Command accepted but requested state was not observed; no command retry was sent');
}
