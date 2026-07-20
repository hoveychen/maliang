import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

// P6 现网切换收尾：清 default 的开发期玩家 A 类脏数据（钱包/委托/进度/发现/位置/背包），
// **绝不碰** characters / character_defs / items / scenes（角色/造物/地形保住——老板硬约束）。
// dry-run 默认（仿 /admin/integrity/fix）：不带 apply 只报告将删多少行，一个字节都不动。

function villager(worldId: string, id: string, name: string): Character {
  return {
    id, worldId, isFairy: false, name, personality: '爱跳', voiceId: 'v-r',
    appearance: { visualDescription: '小动物', spriteAsset: 'hashV', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, sceneId: 'village', abilities: [], relationships: {},
  };
}

// ── persistence 层：purgeWorldPlayerData 只清 A 类 6 表，保角色/造物 ──────────────────
test('P6 purgeWorldPlayerData: dry-run 只报告不删；apply 清 A 类玩家数据但角色/物品存活', () => {
  const s = new WorldStore();
  s.createWorld('default');
  s.saveCharacter(villager('default', 'rabbit1', '舞舞兔')); // 角色（绝不能被清）
  // 造 A 类玩家数据（两个玩家，多张表）
  s.getWallet('default', 'p1'); // 钱包（getWallet 自动发初始花）
  s.bagAdd('default', 'p1', 'tree_puff_a', 2); // 背包
  s.getWallet('default', 'p2');

  // dry-run：报告将删行数，一行不动
  const dry = s.purgeWorldPlayerData('default', false);
  assert.equal(dry.applied, false, 'dry-run 不 apply');
  assert.ok(dry.counts.wallets >= 2, `报告钱包将删 ${dry.counts.wallets} 行`);
  assert.ok(dry.counts.bag >= 1, '报告背包将删');
  // dry-run 后数据仍在
  assert.equal(s.getWallet('default', 'p1').flowers >= 0, true);
  assert.ok(s.getCharacter('default', 'rabbit1'), '角色未动');

  // apply：真删 A 类，角色/世界存活
  const applied = s.purgeWorldPlayerData('default', true);
  assert.equal(applied.applied, true);
  assert.ok(applied.counts.wallets >= 2, 'apply 报告实删钱包行数');
  assert.ok(s.worldExists('default'), 'default 世界本身不删');
  assert.ok(s.getCharacter('default', 'rabbit1'), '角色实例绝不被清（老板硬约束）');
  assert.ok(s.getCharacterDef('rabbit1'), '共享定义也在');
  // 背包被清空
  assert.equal(s.getBag('default', 'p1')['tree_puff_a'] ?? 0, 0, '背包已清');
});

// ── 端点：POST /admin/worlds/:id/purge-player-data，admin 门禁 + dry-run 默认 ──────────
test('P6 purge 端点：token 门禁 + dry-run 默认 + apply=true 才真删', async (t) => {
  const store = new WorldStore();
  store.createWorld('default');
  store.saveCharacter(villager('default', 'rabbit1', '舞舞兔'));
  store.getWallet('default', 'p1');

  const prevToken = process.env.MALIANG_ADMIN_TOKEN;
  process.env.MALIANG_ADMIN_TOKEN = 'sesame'; // debugAuthed 构造时捕获，必须 build 前设
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/worlds/default/purge-player-data';

  try {
    // 门禁
    assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);
    assert.equal((await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'no' } })).statusCode, 403);

    // dry-run（默认，无 apply）：200 + 报告，但不删
    const dry = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(dry.statusCode, 200);
    const dryBody = dry.json() as { applied: boolean; counts: Record<string, number> };
    assert.equal(dryBody.applied, false);
    assert.ok(dryBody.counts.wallets >= 1);
    assert.ok(store.getCharacter('default', 'rabbit1'), 'dry-run 不动角色');

    // apply=true：真删 A 类，角色存活
    const applied = await app.inject({ method: 'POST', url: url + '?apply=true', headers: { 'x-admin-token': 'sesame' } });
    assert.equal(applied.statusCode, 200);
    assert.equal((applied.json() as { applied: boolean }).applied, true);
    assert.ok(store.getCharacter('default', 'rabbit1'), 'apply 后角色仍在');
    assert.ok(store.worldExists('default'), 'default 世界仍在');

    // 不存在的世界 → 404
    assert.equal(
      (await app.inject({ method: 'POST', url: '/admin/worlds/nope/purge-player-data', headers: { 'x-admin-token': 'sesame' } })).statusCode,
      404,
    );
  } finally {
    if (prevToken === undefined) delete process.env.MALIANG_ADMIN_TOKEN;
    else process.env.MALIANG_ADMIN_TOKEN = prevToken;
  }
});
