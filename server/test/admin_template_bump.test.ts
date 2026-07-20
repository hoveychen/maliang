import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

// 管理端点：自增模板放置版本（世界模板架构 v2 P5 的下发开关）。
// 作者把新内容 seed 进 template 后调它，存量玩家世界下次进入触发 additive 补齐。
// 必须过 admin token 门禁；bumpTemplateVersion 内部 ensureTemplateWorld，模板不存在也不炸。

function villager(worldId: string, id: string, name: string): Character {
  return {
    id, worldId, isFairy: false, name, personality: '爱跳', voiceId: 'v-r',
    appearance: { visualDescription: '小动物', spriteAsset: 'hashV', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, sceneId: 'village', abilities: [], relationships: {},
  };
}

test('admin template bump: token 门禁 + 版本自增 + 触发存量世界 additive 补齐', async (t) => {
  const store = new WorldStore();
  store.createWorld('default');
  store.saveCharacter(villager('default', 'rabbit1', '舞舞兔'));
  const wa = store.getOrCreateMyWorld('alice'); // 存量玩家世界（提升 template + clone）

  // debugAuthed 的 token 在 buildServer 构造时一次性捕获（server.ts:961），故必须在 build 前设 env。
  const prevToken = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/template/bump-version';

  try {
    // 无 token → 403
    assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);
    // token 错 → 403
    assert.equal(
      (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode,
      403,
    );

    // 作者往 template 加一个新村民（模拟 seed 进 template）
    store.saveCharacter(villager(TEMPLATE_WORLD_ID, 'newbird', '唱唱鸟'));
    assert.equal(store.getCharacter(wa, 'newbird'), undefined, 'bump 前存量世界没有新村民');

    // 正确 token → 200 + 版本自增为 1
    const res1 = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res1.statusCode, 200);
    assert.equal((res1.json() as { version: number }).version, 1, '首次 bump 版本=1');
    assert.equal(store.getTemplateVersion(TEMPLATE_WORLD_ID), 1);

    // 存量玩家下次进入 → additive 补齐新村民，且不覆盖已有实例
    store.getOrCreateMyWorld('alice');
    const bird = store.getCharacter(wa, 'newbird');
    assert.ok(bird, 'bump 后存量世界补出新村民');
    assert.equal(bird!.name, '唱唱鸟');
    assert.equal(store.getCharacter(wa, 'rabbit1')!.name, '舞舞兔', '原有村民仍在');

    // 再 bump → 版本递增为 2（幂等可重复调）
    const res2 = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal((res2.json() as { version: number }).version, 2, '再 bump 版本=2');
  } finally {
    if (prevToken === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prevToken;
  }
});
