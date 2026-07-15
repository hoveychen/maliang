import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { ItemDef } from '../src/types.ts';

// 背包重做 §2：物品缩略图混合来源。
//  - GET /item-icons：公开只读映射（无 token），游戏客户端背包物品页消费预烧缩略图。
//  - POST /admin/item-icon/:id：离线工具回填入口，admin 门禁 + id 合法性/图片非空校验。
// 本测覆盖公开读半边 + 回填端点的门禁与参数校验（P5：item-icon 回填端点校验）。

// 1×1 透明 PNG（magic 0x89 0x50 → sniffImageMime=image/png）。
const PNG_1x1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

test('item-icons: 公开读 + 回填端点门禁与校验', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  // 一个世界造物（worldId 非空）——回填端点「id 合法性」的世界物品分支。
  const creation: ItemDef = {
    id: 'c-item', worldId: 'w1', name: '小明的城堡', renderRef: 'sdf_inline',
    spec: { name: '小明的城堡', parts: [] } as unknown as ItemDef['spec'],
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
  };
  store.upsertItem(creation);

  // debugAuthed 在 buildServer 时捕获 MALIANG_ADMIN_TOKEN，故必须在建服务器前设好。
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => {
    app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
  });
  const H = { 'x-admin-token': 'sesame' };

  // ── 公开只读：GET /item-icons 无 token 返回映射（初始空）──────────────────────
  const pub0 = await app.inject({ method: 'GET', url: '/item-icons' });
  assert.equal(pub0.statusCode, 200);
  assert.deepEqual(pub0.json(), { icons: {} });

  // ── admin 列表端点仍门禁：无 token → 403 ─────────────────────────────────────
  assert.equal((await app.inject({ method: 'GET', url: '/admin/item-icons' })).statusCode, 403);

  // ── 回填端点门禁：无 token → 403（连 id/图片都不看）─────────────────────────────
  assert.equal(
    (await app.inject({ method: 'POST', url: '/admin/item-icon/tree_puff_a', payload: { pngBase64: PNG_1x1 } })).statusCode,
    403,
  );

  // ── 未知 id → 404（既非内置也非任一世界造物）─────────────────────────────────
  assert.equal(
    (await app.inject({ method: 'POST', url: '/admin/item-icon/nope-xyz', headers: H, payload: { pngBase64: PNG_1x1 } })).statusCode,
    404,
  );

  // ── 缺 pngBase64 → 400 ───────────────────────────────────────────────────────
  assert.equal(
    (await app.inject({ method: 'POST', url: '/admin/item-icon/tree_puff_a', headers: H, payload: {} })).statusCode,
    400,
  );

  // ── 图片解码为空字节 → 400（'!' 是非空串但 base64 解码得 0 字节，命中 empty image 分支）──
  const empty = await app.inject({
    method: 'POST', url: '/admin/item-icon/tree_puff_a', headers: H, payload: { pngBase64: '!' },
  });
  assert.equal(empty.statusCode, 400);
  assert.equal((empty.json() as { error: string }).error, 'empty image');

  // ── 成功（内置 id）：落 putAsset + setItemIcon，回 iconAsset，公开读随即可见 ───────
  const ok = await app.inject({
    method: 'POST', url: '/admin/item-icon/tree_puff_a', headers: H, payload: { pngBase64: PNG_1x1 },
  });
  assert.equal(ok.statusCode, 200);
  const okBody = ok.json() as { itemId: string; iconAsset: string };
  assert.equal(okBody.itemId, 'tree_puff_a');
  assert.ok(okBody.iconAsset.length > 0, 'iconAsset 非空 hash');
  assert.equal(store.getItemIcon('tree_puff_a'), okBody.iconAsset);

  // ── 成功（世界造物 id）：世界物品分支也认 ─────────────────────────────────────
  const ok2 = await app.inject({
    method: 'POST', url: '/admin/item-icon/c-item', headers: H, payload: { pngBase64: PNG_1x1 },
  });
  assert.equal(ok2.statusCode, 200);

  // ── 公开读现在反映两条映射，且资产 hash 对得上 ────────────────────────────────
  const pub1 = await app.inject({ method: 'GET', url: '/item-icons' });
  const icons = (pub1.json() as { icons: Record<string, string> }).icons;
  assert.equal(icons['tree_puff_a'], okBody.iconAsset);
  assert.ok(icons['c-item'] && icons['c-item'].length > 0);
});
