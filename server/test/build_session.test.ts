// 积木式造物（B1，docs/kids-thinking-build-from-parts.md §3.4/§4.1）会话流 P2：
//  ① guideBuild 推进（mock 确定性：按 functionHint 逐槽问、解析输入填槽、必填满则 done）；
//  ② createBuildAsync 落成 composed ItemDef（spec.parts 覆盖已填槽）+ 扣花/退还账目；
//  ③ WS 语音全链路：「造一个小车」→ 命中蓝图升级成拼装 → 逐槽答 → item_created 出组合物；
//  ④ 超轮兜底：卡到 CREATION_MAX_TURNS 用已填零件直接落成，不再无限追问。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  createBuildAsync,
  advanceBuild,
  handleWsMessage,
  newVoiceSession,
  seedFairy,
} from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { ANON_PLAYER, DEFAULT_SCENE, INITIAL_FLOWERS, newCreationState } from '../src/types.ts';
import type { CreationState } from '../src/types.ts';
import { findBlueprint, requiredSlots, type ComposedSpec } from '../src/build_blueprints.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

function freshStore(): WorldStore {
  const path = join(tmpdir(), `maliang-build-${process.hrtime.bigint()}.db`);
  const store = new WorldStore(path);
  store.createWorld('default');
  return store;
}

type ItemDefLike = { id: string; renderRef: string; name: string; worldId: string | null; spec?: ComposedSpec };

// 驱动 guideBuild 一轮，并复刻 advanceBuild 的累积（填槽 + 记问过的槽 + turnCount++），供纯单测逐轮推进。
async function step(adapters: ReturnType<typeof createMockAdapters>, state: CreationState, input: string) {
  const r = await adapters.llm.guideBuild(state, input);
  if (r.filled) state.build!.filled[r.filled.slotId] = r.filled.partId;
  if (r.slotId) state.build!.askedSlots.push(r.slotId);
  state.turnCount += 1;
  return r;
}

test('guideBuild：按 functionHint 逐槽问、把功能词解析成兼容零件填槽、必填满则 done', async () => {
  const adapters = createMockAdapters();
  const state = newCreationState('build', 'car');
  const car = findBlueprint('car')!;

  // 首轮（入口请求）：还没问任何槽 → 问第一个必填槽，选项是该槽兼容零件，尚未填任何零件。
  const r1 = await step(adapters, state, '造一个小车');
  assert.equal(r1.done, false);
  assert.equal(r1.slotId, car.slots[0].slotId, '首轮问第一个必填槽');
  assert.equal(r1.question, car.slots[0].functionHint, '问句就是功能线索（不含零件名）');
  assert.ok((r1.optionIds ?? []).length >= 2, '给至少两个兼容零件可挑');
  assert.equal(r1.filled, undefined, '首轮不填零件');

  // 逐槽用「功能词/语义类」作答，每轮填上一问的槽、再问下一个必填槽。
  const r2 = await step(adapters, state, '车身');
  assert.equal(state.build!.filled['body'], 'body_box', '「车身」→ 填第一个兼容车身零件');
  assert.equal(r2.slotId, 'wheel_back', '接着问下一个必填槽');

  const r3 = await step(adapters, state, '轮子');
  assert.equal(state.build!.filled['wheel_back'], 'wheel_round', '「轮子」→ 填圆轮子');
  assert.equal(r3.slotId, 'wheel_front');

  const r4 = await step(adapters, state, '轮子');
  assert.equal(state.build!.filled['wheel_front'], 'wheel_round');
  assert.equal(r4.slotId, 'handle');

  // 最后一个必填槽填上 → 必填全满 → done。
  const r5 = await step(adapters, state, '把手');
  assert.equal(state.build!.filled['handle'], 'handle_curve');
  assert.equal(r5.done, true, '必填槽全满 → done');

  // 全部必填槽都填上了。
  for (const s of requiredSlots(car)) {
    assert.ok(state.build!.filled[s.slotId], `必填槽 ${s.slotId} 应已填`);
  }
});

test('guideBuild：功能问句绝不泄漏零件名（点点只问功能）', async () => {
  const adapters = createMockAdapters();
  const state = newCreationState('build', 'house');
  const r = await adapters.llm.guideBuild(state, '造一个小房子');
  const partNames = ['砖头墙', '木头墙', '三角屋顶', '拱门', '圆窗'];
  for (const nm of partNames) {
    assert.ok(!(r.question ?? '').includes(nm), `功能问句不该出现零件名「${nm}」`);
  }
});

test('guideBuild：小朋友反悔 → cancelled，不填不落成', async () => {
  const adapters = createMockAdapters();
  const state = newCreationState('build', 'car');
  const r = await adapters.llm.guideBuild(state, '算了不拼了');
  assert.equal(r.cancelled, true);
  assert.equal(r.done, false);
});

test('createBuildAsync：扣花 → item_created，产出 composed: 的 ItemDef，spec.parts 覆盖全部已填槽，进背包', async () => {
  const store = freshStore();
  const sock = fakeSocket();
  const before = store.getWallet('default', ANON_PLAYER).flowers;
  const filled = { body: 'body_box', wheel_back: 'wheel_round', wheel_front: 'wheel_round', handle: 'handle_curve' };
  await createBuildAsync(sock, 'default', ANON_PLAYER, 'car', filled, createMockAdapters(), store);

  const pending = sock.sent.find((m) => m.type === 'prop_pending');
  assert.ok(pending, '应先推 prop_pending');
  const created = sock.sent.find((m) => m.type === 'item_created');
  assert.ok(created, `应推 item_created，收到：${sock.sent.map((m) => m.type).join(',')}`);

  const def = created!.item as ItemDefLike;
  assert.equal(def.renderRef, 'composed:', 'renderRef 是组合物前缀');
  assert.equal(def.worldId, 'default', '组合物实体带 worldId');
  const spec = def.spec!;
  assert.equal(spec.blueprintId, 'car', 'spec 指向蓝图');
  const filledSlots = Object.keys(filled).sort();
  assert.deepEqual(spec.parts.map((p) => p.slotId).sort(), filledSlots, 'spec.parts 覆盖全部已填槽');
  for (const p of spec.parts) {
    assert.ok(p.partId, '每个零件坐位有 partId');
    assert.ok(p.partRenderRef.startsWith('part:'), '冗余零件 renderRef 供客户端画子 quad');
  }

  assert.ok((store.getBag('default', ANON_PLAYER)[def.id] ?? 0) > 0, '组合物进背包');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, before - 1, '扣 1 朵花');

  // 落库后能原样读回（JSON 往返不丢 composed spec）——B3 复用/改装要读这棵零件树。
  const reloaded = store.getItemDef('default', def.id) as ItemDefLike | undefined;
  assert.ok(reloaded, '组合物落库可读回');
  assert.equal((reloaded!.spec as ComposedSpec).parts.length, spec.parts.length);
});

test('createBuildAsync：0 花拦截 → prop_denied，不动账、不出物', async () => {
  const store = freshStore();
  store.spendFlower('default', ANON_PLAYER, INITIAL_FLOWERS); // 花光
  const sock = fakeSocket();
  await createBuildAsync(sock, 'default', ANON_PLAYER, 'car', { body: 'body_box' }, createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'prop_denied' && m.reason === 'no_flowers'), '0 花推 prop_denied');
  assert.ok(!sock.sent.find((m) => m.type === 'item_created'), '不出物');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, 0, '拦截不动账');
});

test('createBuildAsync：一个零件都没填 → prop_failed + 退还那朵花（不白花）', async () => {
  const store = freshStore();
  const before = store.getWallet('default', ANON_PLAYER).flowers;
  const sock = fakeSocket();
  await createBuildAsync(sock, 'default', ANON_PLAYER, 'car', {}, createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'prop_failed'), '空拼装推 prop_failed');
  assert.ok(!sock.sent.find((m) => m.type === 'item_created'), '不出物');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, before, '失败退还花，不白花');
});

test('createBuildAsync：未知蓝图 → prop_failed + 退还', async () => {
  const store = freshStore();
  const before = store.getWallet('default', ANON_PLAYER).flowers;
  const sock = fakeSocket();
  await createBuildAsync(sock, 'default', ANON_PLAYER, 'nope', { x: 'y' }, createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'prop_failed'), '未知蓝图推 prop_failed');
  assert.equal(store.getWallet('default', ANON_PLAYER).flowers, before, '退还花');
});

// 一条 WS 语音全链路：仙子听「造一个小车」→ matchBlueprint 命中 → 升级成积木拼装 → 逐槽答 → item_created。
async function seedWorld(): Promise<{ store: WorldStore; fairyId: string }> {
  const store = freshStore();
  store.upsertScene({
    worldId: 'default', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: 75, terrainVersion: 1, pois: [], portals: [],
  });
  store.addCharacter(seedFairy('default'));
  const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
  return { store, fairyId: fairy.id };
}

async function send(store: WorldStore, session: ReturnType<typeof newVoiceSession>, sock: ReturnType<typeof fakeSocket>, fairyId: string, msg: Record<string, unknown>) {
  await handleWsMessage(
    sock,
    JSON.stringify({ worldId: 'default', characterId: fairyId, ...msg }),
    createMockAdapters(), store, new RateLimiter(1000, 1000), 'test', session,
  );
}

test('WS 全链路：「造一个小车」升级成拼装 → 逐槽答 → item_created 出组合物', async () => {
  const { store, fairyId } = await seedWorld();
  const sock = fakeSocket();
  const session = newVoiceSession();

  // 入口：命中蓝图 → 开拼装会话（发 build_prompt，尚未 item_created）。
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '造一个小车' });
  assert.equal(session.creation?.goal, 'build', '造物入口升级成积木拼装');
  assert.ok(sock.sent.find((m) => m.type === 'build_prompt'), '发拼装选项卡 build_prompt');
  assert.ok(!sock.sent.find((m) => m.type === 'item_created'), '还没落成');

  // 逐槽用功能词作答（会话进行中，transcript 走 advanceBuild 而非 routeIntent）。
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '车身' });
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '轮子' });
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '轮子' });
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '把手' });

  const created = sock.sent.find((m) => m.type === 'item_created');
  assert.ok(created, `应出组合物，收到：${sock.sent.map((m) => m.type).join(',')}`);
  const def = created!.item as ItemDefLike;
  assert.equal(def.renderRef, 'composed:');
  assert.equal((def.spec as ComposedSpec).blueprintId, 'car');
  assert.equal(session.creation, null, '落成后会话清空');
});

test('WS 点选路径：creation_reply 传 partId → 服务端权威填正在问的槽', async () => {
  const { store, fairyId } = await seedWorld();
  const sock = fakeSocket();
  const session = newVoiceSession();
  await send(store, session, sock, fairyId, { type: 'voice_transcript', transcript: '造一个小车' });
  const firstPrompt = sock.sent.find((m) => m.type === 'build_prompt')!;
  assert.equal(firstPrompt.slotId, 'body');
  // 点选 body_round（该槽兼容零件之一）：服务端直接把它坐进 body 槽。
  await send(store, session, sock, fairyId, { type: 'creation_reply', optionId: 'body_round' });
  assert.equal(session.creation?.build?.filled['body'], 'body_round', '点选零件直接填正在问的槽');
});

test('超轮兜底：卡到 CREATION_MAX_TURNS 用已填零件直接落成，不再追问', async () => {
  const { store, fairyId } = await seedWorld();
  const sock = fakeSocket();
  const session = newVoiceSession();
  // 已填一个零件、turnCount 卡到上限（5）。
  session.creation = newCreationState('build', 'car');
  session.creation.build!.filled = { body: 'body_box' };
  session.creation.turnCount = 5;
  await advanceBuild(sock, session, 'default', fairyId, '嗯嗯', createMockAdapters(), store);
  assert.ok(sock.sent.find((m) => m.type === 'item_created'), '超轮直接落成');
  assert.ok(!sock.sent.find((m) => m.type === 'build_prompt'), '不再追问');
  assert.equal(session.creation, null, '会话清空');
});
