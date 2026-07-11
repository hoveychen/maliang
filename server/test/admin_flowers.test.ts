import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, MAX_FLOWERS } from '../src/types.ts';

// 管理端点：给某世界补/设小红花（共享 default 世界初始额度被造角色花光后补花测试用）。
// 只动 flowers、保留盖章进度、必须过 admin token 门禁。
test('admin flowers: token 门禁 + 设值/缺省/夹紧/保留盖章进度', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  // 先花光初始花并盖 1 章，制造 flowers=0、stampProgress=1、stampsTotal=1 的存量态
  assert.equal(store.spendFlower('w1', ANON_PLAYER, INITIAL_FLOWERS), true);
  store.addStamp('w1', ANON_PLAYER);
  assert.deepEqual(store.getWallet('w1', ANON_PLAYER), { flowers: 0, stampProgress: 1, stampsTotal: 1, hearts: 0 });

  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/worlds/w1/flowers';

  // 未配置 MALIANG_ADMIN_TOKEN → 403
  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // token 错 → 403
    assert.equal(
      (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode,
      403,
    );

    // 缺省 body → 补到 INITIAL_FLOWERS，盖章进度不动
    const def = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(def.statusCode, 200);
    assert.deepEqual((def.json() as { wallets: { wallet: unknown }[] }).wallets[0]!.wallet, {
      flowers: INITIAL_FLOWERS,
      stampProgress: 1,
      stampsTotal: 1,
      hearts: 0,
    });

    // 显式值 → 设为该值
    const set2 = await app.inject({
      method: 'POST',
      url,
      headers: { 'x-admin-token': 'sesame' },
      payload: { flowers: 2 },
    });
    assert.equal((set2.json() as { wallets: { wallet: { flowers: number } }[] }).wallets[0]!.wallet.flowers, 2);

    // 超上限 → 夹紧到 MAX_FLOWERS
    const over = await app.inject({
      method: 'POST',
      url,
      headers: { 'x-admin-token': 'sesame' },
      payload: { flowers: 999 },
    });
    assert.equal((over.json() as { wallets: { wallet: { flowers: number } }[] }).wallets[0]!.wallet.flowers, MAX_FLOWERS);

    // 非法值 → 400
    const bad = await app.inject({
      method: 'POST',
      url,
      headers: { 'x-admin-token': 'sesame' },
      payload: { flowers: 'lots' },
    });
    assert.equal(bad.statusCode, 400);

    // 未知世界 → 404
    const missing = await app.inject({
      method: 'POST',
      url: '/admin/worlds/nope/flowers',
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(missing.statusCode, 404);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

// 钱包按玩家分之后：admin 补花可指名道姓，也可一次补全世界所有孩子。
test('admin flowers: 指定 playerId 只补那个孩子；不指定则补齐世界里所有孩子', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.spendFlower('w1', 'A', INITIAL_FLOWERS); // A 花光
  store.spendFlower('w1', 'B', 1);               // B 花掉一朵

  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  const url = '/admin/worlds/w1/flowers';
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // 指名补 A
    const one = await app.inject({
      method: 'POST', url, headers: { 'x-admin-token': 'sesame' }, payload: { playerId: 'A', flowers: 5 },
    });
    assert.equal(one.statusCode, 200);
    assert.deepEqual((one.json() as { wallets: { playerId: string }[] }).wallets.map((w) => w.playerId), ['A']);
    assert.equal(store.getWallet('w1', 'A').flowers, 5);
    assert.equal(store.getWallet('w1', 'B').flowers, INITIAL_FLOWERS - 1, 'B 没被顺带改');

    // 不指名 → 全世界的孩子都补到 MAX
    const all = await app.inject({
      method: 'POST', url, headers: { 'x-admin-token': 'sesame' }, payload: { flowers: MAX_FLOWERS },
    });
    const ids = (all.json() as { wallets: { playerId: string }[] }).wallets.map((w) => w.playerId);
    assert.deepEqual(ids.sort(), ['A', 'B']);
    assert.equal(store.getWallet('w1', 'A').flowers, MAX_FLOWERS);
    assert.equal(store.getWallet('w1', 'B').flowers, MAX_FLOWERS);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});

// 还没建过钱包的孩子也能被指名补花（就地建出来）
test('admin flowers: 指名一个从没露过面的 playerId，就地建钱包', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    await app.inject({
      method: 'POST', url: '/admin/worlds/w1/flowers',
      headers: { 'x-admin-token': 'sesame' }, payload: { playerId: 'newkid', flowers: 7 },
    });
    assert.equal(store.getWallet('w1', 'newkid').flowers, 7);
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
