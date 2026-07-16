// 贴自己贴纸（self-stickers P1，docs/placement-interaction-design.md §3.3 方案 A）：
// 玩家从「装扮」app 把背包里的贴纸贴到自己身上——player_attach handler 落 Player.attachments（服务端权威），
// 经 presenceOf 转发给同场景他人，world_state 回给自己（boot 补回），world_info 重连不抹。覆盖：
//   - 贴上/换装/摘下的背包扣还与 attachments 更新
//   - bad slot / 非贴纸 / 背包无货 三个拒绝路径
//   - presenceOf 带 attachments；world_info upsert 保留旧 attachments（不被 profile 覆盖）；world_state 回 attachments
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession, presenceOf } from '../src/server.ts';

function harness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: any[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  return { store, socket, session, sent };
}

async function say(h: ReturnType<typeof harness>, msg: Record<string, unknown>) {
  await handleWsMessage(
    h.socket, JSON.stringify(msg),
    createMockAdapters(), h.store, new RateLimiter(1000, 1000), 'conn1', h.session,
  );
}

async function register(h: ReturnType<typeof harness>, profile: Record<string, unknown> = { name: '朵朵', spriteAsset: 'deadbeef' }) {
  await say(h, { type: 'world_info', worldId: 'w1', playerId: 'p1', sceneId: 'village', profile });
}

test('player_attach 贴上：背包有贴纸 → 落 attachments + 扣包', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_sun' });
  assert.deepEqual(h.store.getPlayer('p1')?.attachments, [{ slot: 'headTop', itemId: 'sticker_sun' }]);
  assert.equal(h.store.getBag('w1', 'p1')['sticker_sun'] ?? 0, 0, '贴上后背包扣光');
});

test('player_attach 换装：同槽换贴纸 → 旧的回背包', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  h.store.bagAdd('w1', 'p1', 'sticker_star');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_sun' });
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_star' });
  assert.deepEqual(h.store.getPlayer('p1')?.attachments, [{ slot: 'headTop', itemId: 'sticker_star' }]);
  assert.equal(h.store.getBag('w1', 'p1')['sticker_sun'] ?? 0, 1, '旧贴纸回背包');
  assert.equal(h.store.getBag('w1', 'p1')['sticker_star'] ?? 0, 0, '新贴纸已用');
});

test('player_attach 摘下：itemId=null → 移除槽 + 回背包', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'handL', itemId: 'sticker_sun' });
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'handL', itemId: null });
  assert.deepEqual(h.store.getPlayer('p1')?.attachments, [], '摘下后该槽空');
  assert.equal(h.store.getBag('w1', 'p1')['sticker_sun'] ?? 0, 1, '摘下后回背包');
});

test('player_attach 拒绝：bad slot / 非贴纸 / 背包无货 都不改 attachments', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'nose', itemId: 'sticker_sun' });
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'not_a_sticker' });
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_star' }); // 背包没有 star
  assert.equal(h.store.getPlayer('p1')?.attachments ?? undefined, undefined, '三个拒绝路径都没落 attachments');
  assert.equal(h.store.getBag('w1', 'p1')['sticker_sun'] ?? 0, 1, '拒绝不扣包');
  assert.ok(h.sent.some((m) => m.type === 'error'), '应回过 error');
});

test('presenceOf：带上 Player.attachments（别人看到我戴的贴纸）', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_sun' });
  const pres = presenceOf(h.store, 'w1', 'village', 'p1');
  assert.deepEqual(pres.attachments, [{ slot: 'headTop', itemId: 'sticker_sun' }]);
});

test('world_info 重连：profile 不带 attachments，旧 attachments 不被抹（服务端权威）', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'headTop', itemId: 'sticker_sun' });
  // 重连：再来一次 world_info（profile 里没有 attachments）
  await register(h, { name: '朵朵', spriteAsset: 'deadbeef' });
  assert.deepEqual(h.store.getPlayer('p1')?.attachments, [{ slot: 'headTop', itemId: 'sticker_sun' }], '重连不应抹掉贴纸');
});

test('world_state：回自己的 attachments（boot 补回）', async () => {
  const h = harness();
  await register(h);
  h.store.bagAdd('w1', 'p1', 'sticker_sun');
  await say(h, { type: 'player_attach', worldId: 'w1', slot: 'handR', itemId: 'sticker_sun' });
  h.sent.length = 0;
  await register(h); // 再进世界 → world_state
  const ws = h.sent.find((m) => m.type === 'world_state');
  assert.ok(ws, '应回 world_state');
  assert.deepEqual(ws.attachments, [{ slot: 'handR', itemId: 'sticker_sun' }], 'world_state 应带自己的 attachments');
});
