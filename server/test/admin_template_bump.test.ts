import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

// 管理端点：自增模板放置版本。必须过 admin token 门禁；bumpTemplateVersion 内部 ensureTemplateWorld，模板不存在也不炸。
// ★路线 A（角色实例层 base+overlay，char-instance-overlay）后：存量世界的角色【存在】读时从 template base 合成
// → 作者 seed 进 template 的新角色【立即】出现在存量世界，不再依赖 bump/additive。bump 仅剩版本记账 +
// 冗余的 additive 补行（无害、不重复）。本测试相应验证：新角色 bump 前即在 + 版本自增仍工作。

function villager(worldId: string, id: string, name: string): Character {
  return {
    id, worldId, isFairy: false, name, personality: '爱跳', voiceId: 'v-r',
    appearance: { visualDescription: '小动物', spriteAsset: 'hashV', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, sceneId: 'village', abilities: [], relationships: {},
  };
}

test('admin template bump: token 门禁 + 版本自增（路线A：新角色读时合成即在，不靠 bump）', async (t) => {
  const store = new WorldStore();
  store.ensureTemplateWorld(); // P6：空建 template，内容直接 seed 进去
  store.saveCharacter(villager(TEMPLATE_WORLD_ID, 'rabbit1', '舞舞兔'));
  const wa = store.getOrCreateMyWorld('alice'); // 存量玩家世界（从 template clone）

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
    // 路线 A：存在读时从 template base 合成 → 新村民【立即】出现在存量世界，不依赖 bump/additive。
    assert.ok(store.getCharacter(wa, 'newbird'), '路线A：新村民读时合成，bump 前即在存量世界');

    // 正确 token → 200 + 版本自增为 1（版本记账仍工作）
    const res1 = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res1.statusCode, 200);
    assert.equal((res1.json() as { version: number }).version, 1, '首次 bump 版本=1');
    assert.equal(store.getTemplateVersion(TEMPLATE_WORLD_ID), 1);

    // 存量玩家下次进入仍正确（冗余 additive 补行不炸、不重复、不覆盖已有实例）
    store.getOrCreateMyWorld('alice');
    const bird = store.getCharacter(wa, 'newbird');
    assert.ok(bird, '存量世界有新村民');
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
