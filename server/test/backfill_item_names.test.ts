import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { ItemDef } from '../src/types.ts';

// 存量造物名回填中文：/admin/backfill-item-names 把英文 snake_case 名的造物用 LLM 译成短中文名。

function propItem(worldId: string, id: string, name: string): ItemDef {
  return {
    id, worldId, name, renderRef: 'sdf_inline',
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
  };
}

const CJK = /[一-鿿]/;

test('/admin/backfill-item-names：token 门禁 + 英文名译中文 + 中文名跳过 + 幂等', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    store.createWorld('w1');
    store.upsertItem(propItem('w1', 'i-mushroom', 'red_mushroom'));   // 英文 → 应译
    store.upsertItem(propItem('w1', 'i-rocket', 'colorful_rocket'));  // 英文 → 应译
    store.upsertItem(propItem('w1', 'i-cn', '小蘑菇'));               // 已中文 → 跳过

    const url = '/admin/backfill-item-names?world=w1';

    // 门禁
    delete process.env.MALIANG_ADMIN_TOKEN;
    assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);
    process.env.MALIANG_ADMIN_TOKEN = 'sesame';
    assert.equal(
      (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'no' } })).statusCode, 403,
    );

    // 回填
    const res = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { count: number; renamed: number; results: { id: string; old: string; name?: string; skipped?: string }[] };
    assert.equal(body.renamed, 2, '两件英文名被译');

    // 库里名字确实变中文了
    const mushroom = store.listWorldItems('w1').find((d) => d.id === 'i-mushroom')!;
    const rocket = store.listWorldItems('w1').find((d) => d.id === 'i-rocket')!;
    const cn = store.listWorldItems('w1').find((d) => d.id === 'i-cn')!;
    assert.ok(CJK.test(mushroom.name) && !/[a-zA-Z_]/.test(mushroom.name), `mushroom → 中文，实为 ${mushroom.name}`);
    assert.ok(CJK.test(rocket.name) && !/[a-zA-Z_]/.test(rocket.name), `rocket → 中文，实为 ${rocket.name}`);
    assert.equal(cn.name, '小蘑菇', '已中文的不动');

    // 幂等：再跑一次，0 renamed（全已中文）
    const again = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal((again.json() as { renamed: number }).renamed, 0, '幂等：二次回填不再改名');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});
