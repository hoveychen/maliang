// B3 语音起名（reuse-name，docs/kids-thinking-reuse-name.md §5）：name_creation WS handler。
// 只回填【属于该 player 背包】的造物，非法/越权 itemId 拒绝，录音存资产并回填 nameVoiceAsset/nameText，幂等可覆盖。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer, handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import type { ItemDef } from '../src/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function seeded(): Promise<{ store: WorldStore; close: () => Promise<void> }> {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  await app.inject({ method: 'GET', url: '/worlds/default' });
  return { store, close: () => app.close() };
}

async function ws(store: WorldStore, session: VoiceSession, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, new RateLimiter(100, 100), 'test', session);
  return sock.sent;
}

/** 造一件进背包的语音造物（最小 ItemDef）。 */
function seedBagItem(store: WorldStore, playerId: string, id: string, name: string): ItemDef {
  const def: ItemDef = {
    id, worldId: 'default', name, renderRef: 'sdf_inline',
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
  };
  store.upsertItem(def);
  store.bagAdd('default', playerId, id);
  return def;
}

/** 造一件已摆放到世界、【不在背包】但由该 player 造的物件——复现真机造物自动摆放后的起名。 */
function seedPlacedCreation(store: WorldStore, creatorPlayerId: string, id: string, name: string): ItemDef {
  const def: ItemDef = {
    id, worldId: 'default', name, renderRef: 'sdf_inline',
    footprintW: 1, footprintH: 1, blocking: true, pathOk: true, wander: 0,
    creatorPlayerId,
  };
  store.upsertItem(def);
  // 关键：不 bagAdd —— 造物已被客户端自动摆放到世界（server bagTake 移出背包），不在背包里。
  return def;
}

const AUDIO = Buffer.from('fake-wav-bytes').toString('base64');

test('name_creation：给自己造的、已摆放到世界（不在背包）的物件起名 → 落库（真机造物自动摆放后起名的真身）', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    seedPlacedCreation(store, 'kid-1', 'ladder-2', '梯子');
    const sent = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'ladder-2', audio: AUDIO, text: '爬爬梯' });
    const updated = sent.find((m) => m.type === 'item_updated');
    assert.ok(updated, `应回 item_updated（造物者是本人应放行），实际：${sent.map((m) => m.type).join(',')}`);
    const fromStore = store.getItemDef('default', 'ladder-2')!;
    assert.ok(fromStore.nameVoiceAsset && fromStore.nameVoiceAsset.length > 0, 'nameVoiceAsset 应落库');
    assert.equal(fromStore.nameText, '爬爬梯', 'nameText 应落库');
  } finally {
    await close();
  }
});

test('name_creation：给别人造的、已摆放物件起名 → 拒（造物者不符且不在自己背包，越权仍挡）', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    seedPlacedCreation(store, 'kid-2', 'other-2', '别人造的梯子');
    const sent = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'other-2', audio: AUDIO, text: '偷起名' });
    assert.ok(sent.some((m) => m.type === 'error'), '越权起名应回 error');
    assert.equal(sent.some((m) => m.type === 'item_updated'), false, '不回 item_updated');
    assert.equal(store.getItemDef('default', 'other-2')!.nameVoiceAsset, undefined, '别人的造物没被改');
  } finally {
    await close();
  }
});

test('name_creation：回填自己背包里造物的 nameVoiceAsset + nameText → item_updated', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    seedBagItem(store, 'kid-1', 'ladder-1', '梯子');
    const sent = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'ladder-1', audio: AUDIO, text: '爬爬梯' });
    const updated = sent.find((m) => m.type === 'item_updated');
    assert.ok(updated, `应回 item_updated，实际：${sent.map((m) => m.type).join(',')}`);
    const item = updated!.item as ItemDef;
    assert.ok(item.nameVoiceAsset && item.nameVoiceAsset.length > 0, 'nameVoiceAsset 应落资产哈希');
    assert.equal(item.nameText, '爬爬梯', 'nameText 落 ASR 文本');
    // 落库可回读
    const fromStore = store.getItemDef('default', 'ladder-1')!;
    assert.equal(fromStore.nameVoiceAsset, item.nameVoiceAsset, 'upsert 回填持久');
    assert.equal(fromStore.nameText, '爬爬梯');
    // 录音资产可取回
    assert.ok(store.getAsset(item.nameVoiceAsset!), '录音资产入库可取回');
  } finally {
    await close();
  }
});

test('name_creation：itemId 不在该 player 背包 → 拒绝，不改任何东西', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    // 造物属于另一个孩子的背包（kid-2），kid-1 不能给它起名
    seedBagItem(store, 'kid-2', 'other-1', '别人的梯子');
    const sent = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'other-1', audio: AUDIO, text: '偷起名' });
    assert.ok(sent.some((m) => m.type === 'error'), '越权起名应回 error');
    assert.equal(sent.some((m) => m.type === 'item_updated'), false, '不回 item_updated');
    assert.equal(store.getItemDef('default', 'other-1')!.nameVoiceAsset, undefined, '别人的造物没被改');
  } finally {
    await close();
  }
});

test('name_creation：内置物（worldId===null）不可起名', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    // 直接把一个内置贴纸塞进背包（buy 路径之外的最简造法），验 not nameable
    store.bagAdd('default', 'kid-1', 'sticker_sun');
    const sent = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'sticker_sun', audio: AUDIO });
    assert.ok(sent.some((m) => m.type === 'error'), '内置物不可起名');
    assert.equal(sent.some((m) => m.type === 'item_updated'), false);
  } finally {
    await close();
  }
});

test('name_creation：再起名覆盖旧录音（幂等可改）', async () => {
  const { store, close } = await seeded();
  try {
    const session = newVoiceSession();
    session.playerId = 'kid-1';
    seedBagItem(store, 'kid-1', 'ladder-1', '梯子');
    const first = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'ladder-1', audio: AUDIO, text: '一号' });
    const h1 = (first.find((m) => m.type === 'item_updated')!.item as ItemDef).nameVoiceAsset;
    const AUDIO2 = Buffer.from('another-wav').toString('base64');
    const second = await ws(store, session, { type: 'name_creation', worldId: 'default', itemId: 'ladder-1', audio: AUDIO2, text: '二号' });
    const item2 = second.find((m) => m.type === 'item_updated')!.item as ItemDef;
    assert.notEqual(item2.nameVoiceAsset, h1, '新录音换新哈希');
    assert.equal(item2.nameText, '二号', '文本也更新');
    assert.equal(store.getItemDef('default', 'ladder-1')!.nameText, '二号');
  } finally {
    await close();
  }
});
