import { test } from "node:test";
import assert from "node:assert/strict";
import { diffState } from "../src/delta.ts";

test("值变化 → changed[k]=[旧,新]，不含未变项", () => {
  const d = diffState({ a: 1, b: 2 }, { a: 1, b: 9 });
  assert.deepEqual(d.changed, { b: [2, 9] });
  assert.deepEqual(d.added, {});
  assert.deepEqual(d.removed, {});
});

test("新增 key → added（key-absence 有别于值变）", () => {
  const d = diffState({ a: 1 }, { a: 1, phone_open: true });
  assert.deepEqual(d.added, { phone_open: true });
  assert.deepEqual(d.changed, {});
});

test("移除 key → removed", () => {
  const d = diffState({ a: 1, active_task: { id: "t" } }, { a: 1 });
  assert.deepEqual(d.removed, { active_task: { id: "t" } });
  assert.deepEqual(d.changed, {});
});

test("嵌套对象按值深比", () => {
  assert.deepEqual(diffState({ w: { f: 1 } }, { w: { f: 2 } }).changed, { w: [{ f: 1 }, { f: 2 }] });
  assert.deepEqual(diffState({ w: { f: 1 } }, { w: { f: 1 } }).changed, {});
});

test("空/同快照", () => {
  assert.deepEqual(diffState(null, { a: 1 }).added, { a: 1 });
  assert.deepEqual(diffState({ a: 1 }, null).removed, { a: 1 });
  const same = { fsm_state: "EXPLORE", npc_count: 8 };
  assert.deepEqual(diffState(same, { ...same }), { changed: {}, added: {}, removed: {} });
});
