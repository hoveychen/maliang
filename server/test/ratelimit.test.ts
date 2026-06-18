import { test } from 'node:test';
import assert from 'node:assert/strict';
import { RateLimiter } from '../src/ratelimit.ts';

test('每连接限频：超过 perMin 被挡，窗口滑出后恢复', () => {
  const rl = new RateLimiter(3, 100);
  const k = 'conn1';
  const t0 = 1_000_000;
  for (let i = 0; i < 3; i++) {
    const r = rl.tryAcquire(k, t0 + i);
    assert.equal(r.ok, true);
    if (r.ok) r.release(); // 释放全局，但仍占窗口
  }
  const denied = rl.tryAcquire(k, t0 + 4);
  assert.equal(denied.ok, false);
  if (!denied.ok) assert.match(denied.reason, /太快/);
  // 61s 后窗口滑出
  const ok = rl.tryAcquire(k, t0 + 61_000);
  assert.equal(ok.ok, true);
});

test('全局并发上限：达到 globalMax 后挡，release 后恢复', () => {
  const rl = new RateLimiter(100, 2);
  const a = rl.tryAcquire('c1', 1);
  const b = rl.tryAcquire('c2', 1);
  assert.equal(a.ok, true);
  assert.equal(b.ok, true);
  assert.equal(rl.activeCount, 2);
  const c = rl.tryAcquire('c3', 1);
  assert.equal(c.ok, false);
  if (!c.ok) assert.match(c.reason, /好多小朋友|稍等/);
  if (a.ok) a.release();
  assert.equal(rl.activeCount, 1);
  const d = rl.tryAcquire('c3', 1);
  assert.equal(d.ok, true);
});

test('不同连接互不影响限频', () => {
  const rl = new RateLimiter(1, 100);
  const a = rl.tryAcquire('c1', 1);
  assert.equal(a.ok, true);
  if (a.ok) a.release();
  const a2 = rl.tryAcquire('c1', 2);
  assert.equal(a2.ok, false); // c1 超频
  const b = rl.tryAcquire('c2', 2);
  assert.equal(b.ok, true); // c2 不受影响
});
