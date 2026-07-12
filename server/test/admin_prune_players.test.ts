import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Player } from '../src/types.ts';

function player(id: string, over: Partial<Player> = {}): Player {
  return { id, name: '', nickname: '', gender: '', color: '', spriteAsset: '', createdAt: '', ...over };
}

// 管理端点：清后台「无立绘」空玩家档（name 与 spriteAsset 均空）。必须过 admin token 门禁，
// 只删空档、保留有真角色的行。
test('admin prune-empty-players: token 门禁 + 只删空档', async (t) => {
  const store = new WorldStore();
  store.upsertPlayer(player('empty1'));
  store.upsertPlayer(player('empty2', { createdAt: '2026-07-10' })); // 有 createdAt 但无名无立绘 = 空档
  store.upsertPlayer(player('named', { name: '朵朵' }));
  store.upsertPlayer(player('sprited', { spriteAsset: 'deadbeef' }));
  assert.equal(store.listPlayers().length, 4);

  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/players/prune-empty';

  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    assert.equal(
      (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode,
      403,
    );

    const res = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { removed: number; playerIds: string[] };
    assert.equal(body.removed, 2);
    assert.deepEqual([...body.playerIds].sort(), ['empty1', 'empty2']);

    // 只剩两个有真角色的
    assert.deepEqual(
      store.listPlayers().map((p) => p.id).sort(),
      ['named', 'sprited'],
    );

    // 幂等：再清一次删 0 条
    const again = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal((again.json() as { removed: number }).removed, 0);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
