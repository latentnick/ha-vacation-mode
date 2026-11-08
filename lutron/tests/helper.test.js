import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

test('failed monitor exits even while its parent keeps stdin open', async () => {
  const child = spawn(process.execPath, [new URL('../app-helper.js', import.meta.url).pathname], { stdio: ['pipe', 'pipe', 'pipe'] });
  const timer = setTimeout(() => child.kill(), 2000);
  try {
    const exited = once(child, 'exit');
    child.stdin.on('error', () => {});
    child.stdin.write(JSON.stringify({ command: 'monitor', host: 'localhost', identity: {}, zones: ['/zone/2'] }) + '\n');
    const [code, signal] = await exited;
    assert.equal(signal, null, 'helper must exit without being killed');
    assert.equal(code, 1);
  } finally {
    clearTimeout(timer);
    child.kill();
  }
});
