import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldHub } from '../src/world_hub.ts';
import { StageDirector } from '../src/stage_session.ts';

const ACTORS = [{ id: 'a1', name: '小鸭', isPlayer: false }];

async function waitFor(pred: () => boolean, ms = 3000): Promise<void> {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > ms) throw new Error('waitFor 超时');
    await new Promise((r) => setTimeout(r, 5));
  }
}

test('全局并发上限: 达上限拒绝开演, 释放一个后可再开', async () => {
  const hub = new WorldHub();
  const dir = new StageDirector(hub, undefined, 2); // 上限 2
  assert.equal(dir.maxConcurrent, 2);

  // 两场长演出各占一 worker(slot 在 startStage 同步登记,不必等 worker spawn)。
  const p1 = dir.startStage('w1', { code: 'await stage.sleep(600);', actors: ACTORS });
  const p2 = dir.startStage('w2', { code: 'await stage.sleep(600);', actors: ACTORS });
  assert.ok(p1 && p2, '前两场应开成');
  assert.equal(dir.activeCount, 2);
  assert.equal(dir.atCapacity(), true, '达上限');

  // 第三场:全局上限拒绝(返 null),即使 w3 本身没在演出。
  const p3 = dir.startStage('w3', { code: 'stage.end();', actors: ACTORS });
  assert.equal(p3, null, '达上限时拒绝开演');

  // 每世界守卫仍独立生效:重复开 w1 也返 null(已在演出)。
  assert.equal(dir.startStage('w1', { code: 'stage.end();', actors: ACTORS }), null);

  // 释放一场 → 容量回落 → 第三场可开。
  dir.onWorldEmpty('w1');
  await waitFor(() => !dir.atCapacity());
  assert.equal(dir.activeCount, 1);
  const p3b = dir.startStage('w3', { code: 'await stage.sleep(600);', actors: ACTORS });
  assert.ok(p3b, '释放后应能再开');
  assert.equal(dir.atCapacity(), true);

  // 清理:杀掉所有 worker 让测试进程退出。
  dir.onWorldEmpty('w2');
  dir.onWorldEmpty('w3');
  await Promise.allSettled([p1, p2, p3b]);
});
