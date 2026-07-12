// 造贴纸落地（fairy-stickers P2）：createStickerAsync 扣花→生图管线→mount:edge+资产哈希 ItemDef→背包→item_created；
// 0 花拦截、审核挡退花，以及 WS 语音引导全链路（仙子听「做个太阳贴纸」→ item_created 出贴纸）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createStickerAsync, handleWsMessage, newVoiceSession, seedFairy } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { ANON_PLAYER, DEFAULT_SCENE, INITIAL_FLOWERS } from '../src/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

function freshStore(): WorldStore {
  const path = join(tmpdir(), `maliang-sticker-${process.hrtime.bigint()}.db`);
  const store = new WorldStore(path);
  store.createWorld('default');
  return store;
}

type ItemDef = { id: string; renderRef: string; mount?: string; blocking: boolean; worldId: string | null; footprintW: number };

test('createStickerAsync：扣花→item_created，产出 mount:edge + sticker:@hash 的 ItemDef，进背包', async () => {
  const store = freshStore();
  const sock = fakeSocket();
  const before = store.getWallet('default', ANON_PLAYER).flowers;
  await createStickerAsync(sock, 'default', ANON_PLAYER, '一个红的太阳贴纸', createMockAdapters(), store);

  // 先报 sticker_pending，再报 item_created
  const pending = sock.sent.find((m) => m.type === 'sticker_pending');
  assert.ok(pending, '应先推 sticker_pending');
  const created = sock.sent.find((m) => m.type === 'item_created');
  assert.ok(created, '应推 item_created');

  const def = created!.item as ItemDef;
  assert.equal(def.mount, 'edge', '贴纸挂边缘');
  assert.ok(def.renderRef.startsWith('sticker:@'), `renderRef 应是资产哈希贴纸，实际 ${def.renderRef}`);
  assert.equal(def.blocking, false, '贴纸不挡路');
  assert.equal(def.footprintW, 1, '贴纸 1×1');
  assert.equal(def.worldId, 'default', '造物实体带 worldId');

  // 进了背包 + 扣了 1 朵花（getBag 返回 item_id→count）
  assert.ok((store.getBag('default', ANON_PLAYER)[def.id] ?? 0) > 0, '贴纸进背包');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, before - 1, '扣 1 朵花');
});

test('createStickerAsync：0 花拦截 → prop_denied，不动账、不出贴纸', async () => {
  const store = freshStore();
  store.spendFlower('default', ANON_PLAYER, INITIAL_FLOWERS); // 花光
  const sock = fakeSocket();
  await createStickerAsync(sock, 'default', ANON_PLAYER, '一个太阳贴纸', createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'prop_denied' && m.reason === 'no_flowers'), '0 花推 prop_denied');
  assert.ok(!sock.sent.find((m) => m.type === 'item_created'), '不出贴纸');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, 0, '拦截不动账');
});

test('createStickerAsync：审核挡下 → sticker_failed + 退还那朵花', async () => {
  const store = freshStore();
  const before = store.getWallet('default', ANON_PLAYER).flowers;
  const sock = fakeSocket();
  await createStickerAsync(sock, 'default', ANON_PLAYER, '一个武器贴纸', createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'sticker_failed'), '审核挡推 sticker_failed');
  assert.ok(!sock.sent.find((m) => m.type === 'item_created'), '不出贴纸');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, before, '被挡退还花，不白花');
});

test('WS 语音全链路：仙子听「做个太阳贴纸」→ 引导会话 done → item_created 出贴纸', async () => {
  const store = freshStore();
  store.upsertScene({
    worldId: 'default', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: 75, terrainVersion: 1, pois: [], portals: [],
  });
  store.addCharacter(seedFairy('default')); // freshStore 只建世界，仙子需显式种
  const fairy = store.listCharacters('default').find((c) => c.isFairy);
  assert.ok(fairy, '默认世界应有小仙子');

  const sock = fakeSocket();
  const session = newVoiceSession();
  await handleWsMessage(
    sock,
    JSON.stringify({ type: 'voice_transcript', worldId: 'default', characterId: fairy!.id, transcript: '做个太阳贴纸' }),
    createMockAdapters(), store, new RateLimiter(100, 100), 'test', session,
  );
  // 「太阳」一句说全 → guideSticker 首轮即 done → 直接开造 → item_created
  const created = sock.sent.find((m) => m.type === 'item_created');
  assert.ok(created, `应出贴纸，收到消息类型：${sock.sent.map((m) => m.type).join(',')}`);
  const def = created!.item as ItemDef;
  assert.equal(def.mount, 'edge');
  assert.ok(def.renderRef.startsWith('sticker:@'));
});
