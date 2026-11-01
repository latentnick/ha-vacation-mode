import { EventEmitter } from 'node:events';
import { randomUUID } from 'node:crypto';

// Newline framing must handle split TLS records and multiple messages per record.
export class Frames {
  buffer = '';
  push(chunk) {
    this.buffer += chunk;
    if (this.buffer.length > 4 * 1024 * 1024) throw new Error('LEAP frame too large');
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop();
    return lines.filter(line => line.trim()).map(line => {
      const message = JSON.parse(line);
      if (!message || typeof message !== 'object' || Array.isArray(message) ||
          !message.Header || typeof message.Header !== 'object' || Array.isArray(message.Header)) {
        throw new Error('Invalid LEAP message envelope');
      }
      return message;
    });
  }
}

export class Connection extends EventEmitter {
  pending = new Map();
  constructor(socket) {
    super();
    this.socket = socket;
    const frames = new Frames();
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      try {
        for (const message of frames.push(chunk)) {
          const pending = this.pending.get(message.Header?.ClientTag);
          if (pending) {
            clearTimeout(pending.timer);
            this.pending.delete(message.Header.ClientTag);
            if (!/^2\d\d(?: |$)/.test(String(message.Header.StatusCode))) {
              pending.reject(new Error(`LEAP ${message.Header.StatusCode}`));
            } else pending.resolve(message);
          }
          this.emit('message', message);
        }
      } catch (error) { socket.destroy(error); }
    });
    socket.on('error', error => { this.failure = error; });
    socket.on('close', () => {
      for (const pending of this.pending.values()) {
        clearTimeout(pending.timer);
        pending.reject(this.failure ?? new Error('Disconnected'));
      }
      this.pending.clear();
      this.emit('closed');
    });
  }
  request(type, url) {
    if (!['ReadRequest', 'SubscribeRequest'].includes(type)) throw new Error('Read-only connection');
    return this.#request(type, url);
  }
  setSwitch(zone, on) {
    if (!/^\/zone\/[1-9]\d*$/.test(zone) || typeof on !== 'boolean') throw new Error('Invalid switch command');
    return this.#request('CreateRequest', `${zone}/commandprocessor`, {
      Command: { CommandType: 'GoToLevel', Parameter: [{ Type: 'Level', Value: on ? 100 : 0 }] },
    });
  }
  #request(type, url, body) {
    if (typeof url !== 'string' || !url.startsWith('/') || url.length > 2048) throw new Error('Invalid LEAP resource URL');
    if (this.pending.size >= 64) return Promise.reject(new Error('Too many pending LEAP requests'));
    if (this.socket.destroyed) return Promise.reject(new Error('Disconnected'));
    const tag = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(tag);
        reject(new Error(`Timeout reading ${url}`));
      }, 10000);
      this.pending.set(tag, { resolve, reject, timer });
      this.socket.write(JSON.stringify({ CommuniqueType: type, Header: { ClientTag: tag, Url: url }, ...(body ? { Body: body } : {}) }) + '\n');
    });
  }
}

export function zoneStates(message) {
  const body = message.Body ?? {};
  return (body.ZoneStatuses ?? (body.ZoneStatus ? [body.ZoneStatus] : []))
    .filter(zone => typeof zone.Level === 'number' && zone.Level >= 0 && zone.Level <= 100 && zone.Zone?.href)
    .map(zone => ({ zone: zone.Zone.href, level: zone.Level, on: zone.Level > 0 }));
}
