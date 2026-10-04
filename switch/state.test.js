import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { restoreState } from "./state.js";

for (const on of [true, false]) {
  test(`restart preserves away mode ${on}`, (t) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lights-state-"));
    t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
    const file = path.join(dir, "state.json");
    fs.writeFileSync(file, JSON.stringify({ on, updated: new Date().toISOString() }));
    assert.equal(restoreState(file), on);
    assert.equal(restoreState(file), on);
  });
}
test("first launch and malformed state default to off", (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "lights-state-"));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, "state.json");
  assert.equal(restoreState(file), false);
  for (const data of ["{", "null", '{}', '{"on":"true"}']) {
    fs.writeFileSync(file, data);
    assert.equal(restoreState(file), false);
  }
});
