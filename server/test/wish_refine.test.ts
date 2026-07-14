// 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §5）：心愿两段完成的服务端判定。
//  ① beginWishTrial：造成功开试用——按造出来的档反推调整方向（big/medium→smaller、small→bigger）。
//  ② completeWishRefine：方向对即盖章一次；方向错不动账只 refineTries++；达上限无条件盖章（绝不第三次挑刺）。
//  ③ completeWishOnAbility：无体型可调的能力（play_game/guide_to）仍一段完成，不受两段化影响。
//  ④ WS wish_refine：调对 → task_complete + 村民道谢；调反 → wish_retry（仙子再问一句）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { beginWishTrial, completeWishRefine, completeWishOnAbility } from '../src/tasks.ts';
import { refineDirFor, REFINE_MAX_TRIES } from '../src/refinements.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { WorldHub } from '../src/world_hub.ts';
import { creationItemDef } from '../src/items.ts';
import { fallbackSdfPropSpec } from '../src/sdf_prop.ts';
import { emptyTerrain, encodeTerrain, REQUIRED_GRID } from '../src/terrain.ts';
import { sizeToScale } from '../src/creation_options.ts';
import { ANON_PLAYER, DEFAULT_SCENE, type ActiveTask, type Character } from '../src/types.ts';

function seedWorld(): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  const npc: Character = {
    id: 'npc1', worldId: 'w1', isFairy: false, name: '小兔', personality: 'p', voiceId: 'v-npc1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
  };
  store.addCharacter(npc);
  return store;
}

function setWish(store: WorldStore, ability: string): void {
  const task: ActiveTask = { id: 't1', type: 'wish', npcId: 'npc1', npcName: '小兔', stampStyle: 'smile', wishAbility: ability };
  store.setActiveTask('w1', ANON_PLAYER, task);
}

test('refineDirFor：big/medium 抱怨太大(可变小)、small 抱怨太小(可变大)——方向永远够得到', () => {
  assert.equal(refineDirFor('big'), 'smaller');
  assert.equal(refineDirFor('medium'), 'smaller');
  assert.equal(refineDirFor('small'), 'bigger');
});

test('beginWishTrial：标记 tried + 按造出来的档定方向 + 记引用；返回抱怨方向', () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  const r = beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'big', store);
  assert.ok(r, '匹配的 pending 心愿应开成试用');
  assert.equal(r!.dir, 'smaller', 'big → 抱怨太大 → 该变小');
  const task = store.getActiveTask('w1', ANON_PLAYER)!;
  assert.equal(task.wishStage, 'tried');
  assert.equal(task.refineItemRef, 'item-9');
  assert.equal(task.refineDir, 'smaller');
  assert.equal(task.refineFromSize, 'big');
  assert.equal(task.refineTries, 0);
});

test('beginWishTrial：无匹配心愿 / 已在试用中 → null（不重开、不误开）', () => {
  const store = seedWorld();
  assert.equal(beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'i', 'big', store), null, '没委托 → null');
  setWish(store, 'create_character');
  assert.equal(beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'i', 'big', store), null, '能力对不上 → null');
  setWish(store, 'create_prop');
  assert.ok(beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'i', 'big', store), '首次开成');
  assert.equal(beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'i', 'big', store), null, '已 tried → 不重开');
});

test('completeWishRefine：方向调对 → 立刻盖章 + 清委托', () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'big', store); // 该变小
  const r = completeWishRefine('w1', ANON_PLAYER, 'item-9', 'medium', store); // big→medium=变小=对
  assert.ok(r && r.satisfied, '方向对 → satisfied');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 1, '盖 1 章');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '满意后清委托');
});

test('completeWishRefine：方向调反且未达上限 → 不动账、refineTries++、返回 retry', () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'medium', store); // medium 该变小
  const r = completeWishRefine('w1', ANON_PLAYER, 'item-9', 'big', store); // medium→big=变大=反
  assert.ok(r && !r.satisfied, '方向反 → 不满意');
  assert.equal((r as { tries: number }).tries, 1, 'refineTries 记到 1');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 0, '调反不盖章');
  const task = store.getActiveTask('w1', ANON_PLAYER)!;
  assert.equal(task.wishStage, 'tried', '委托还在试用');
  assert.equal(task.refineTries, 1);
});

test('completeWishRefine：达上限无条件盖章——绝不第三次挑刺', () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'medium', store); // 该变小
  // 连续两次都调反（变大），第二次到上限 → 无论调成什么都盖章。
  const r1 = completeWishRefine('w1', ANON_PLAYER, 'item-9', 'big', store);
  assert.ok(r1 && !r1.satisfied, '第一次调反：还没到上限');
  const r2 = completeWishRefine('w1', ANON_PLAYER, 'item-9', 'big', store);
  assert.ok(r2 && r2.satisfied, `到第 ${REFINE_MAX_TRIES} 次无条件盖章`);
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 1, '收尾盖 1 章');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '收尾清委托');
});

test('completeWishRefine：itemRef 对不上 / 委托不在试用 → null（不误结算）', () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  assert.equal(completeWishRefine('w1', ANON_PLAYER, 'item-9', 'small', store), null, 'pending(没试用) → null');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'big', store);
  assert.equal(completeWishRefine('w1', ANON_PLAYER, 'other-item', 'small', store), null, 'itemRef 不符 → null');
});

test('completeWishOnAbility：无体型可调的能力(play_game)仍一段完成，不受两段化影响', () => {
  const store = seedWorld();
  setWish(store, 'play_game');
  const done = completeWishOnAbility('w1', ANON_PLAYER, 'play_game', store);
  assert.ok(done, 'play_game 心愿一段完成');
  assert.equal(store.getWallet('w1', ANON_PLAYER).stampsTotal, 1, '当场盖章');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '当场清委托');
});

// ── WS 全链路：wish_refine 上报 → 满意盖章 / 不满意再问 ──
function collect(): { sent: Record<string, unknown>[]; socket: { send: (s: string) => void } } {
  const sent: Record<string, unknown>[] = [];
  return { sent, socket: { send: (s: string) => sent.push(JSON.parse(s)) } };
}
async function send(store: WorldStore, session: ReturnType<typeof newVoiceSession>, sock: ReturnType<typeof collect>, msg: Record<string, unknown>) {
  await handleWsMessage(sock.socket, JSON.stringify({ worldId: 'w1', ...msg }), createMockAdapters(), store, new RateLimiter(1000, 1000), 'test', session);
}

test('WS wish_refine：调对 → task_complete + 村民道谢', async () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'big', store); // 该变小
  const sock = collect();
  const session = newVoiceSession();
  await send(store, session, sock, { type: 'wish_refine', itemRef: 'item-9', newSize: 'small' }); // big→small=变小=对
  assert.ok(sock.sent.some((m) => m['type'] === 'task_complete'), '调对 → 盖章庆祝');
  assert.ok(sock.sent.some((m) => m['type'] === 'praise_tts' && m['voiceId'] === 'v-npc1'), '村民用自己音色道谢');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER), null, '满意清委托');
});

test('WS wish_refine：调反(未达上限) → wish_retry，仙子再问一句', async () => {
  const store = seedWorld();
  setWish(store, 'create_prop');
  beginWishTrial('w1', ANON_PLAYER, 'create_prop', 'item-9', 'medium', store); // 该变小
  const sock = collect();
  const session = newVoiceSession();
  await send(store, session, sock, { type: 'wish_refine', itemRef: 'item-9', newSize: 'big' }); // 反
  assert.ok(!sock.sent.some((m) => m['type'] === 'task_complete'), '调反不盖章');
  const retry = sock.sent.find((m) => m['type'] === 'wish_retry');
  assert.ok(retry, '调反 → wish_retry');
  assert.equal(retry!['fairyHint'], 'refine_hint_2', '升一级问句');
  assert.equal(store.getActiveTask('w1', ANON_PLAYER)!.refineTries, 1);
});

// ── P7：wish_refine 除判定外还【应用体型 + 广播重渲染】（老板拍板：服务端改尺寸）──
const G = REQUIRED_GRID;

/** 真 hub + 两条连接：观察定向/世界广播。 */
function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const hub = new WorldHub();
  const conn = (connKey: string, playerId: string) => {
    const sent: Record<string, unknown>[] = [];
    const session = newVoiceSession();
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const say = (msg: object) =>
      handleWsMessage(socket, JSON.stringify({ worldId: 'w1', playerId, ...msg }), createMockAdapters(), store, new RateLimiter(1000, 1000), connKey, session, hub);
    return { sent, say, ofType: (t: string) => sent.filter((m) => m['type'] === t) };
  };
  return { store, conn };
}

test('WS wish_refine（角色）：改 appearance.size/scale + 向同场景广播 character_resized', async () => {
  const { store, conn } = rig();
  // 造出来的新伙伴（refine 目标）落在 village，初始 big。
  const buddy: Character = {
    id: 'buddy', worldId: 'w1', isFairy: false, name: '小龙', personality: 'p', voiceId: 'v-buddy',
    appearance: { visualDescription: '', spriteAsset: '', scale: sizeToScale('big'), size: 'big' },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 5, tileY: 5 }, abilities: [], relationships: {}, sceneId: DEFAULT_SCENE,
  };
  store.addCharacter(buddy);
  // pa 的试用：造出来是 big（该变小），refineItemRef 指向 buddy。
  store.setActiveTask('w1', 'pa', {
    id: 't1', type: 'wish', npcId: 'buddy', npcName: '小龙', stampStyle: 'smile',
    wishAbility: 'create_character', wishStage: 'tried', refineItemRef: 'buddy',
    refineDir: 'smaller', refineFromSize: 'big', refineTries: 0,
  });
  const a = conn('cA', 'pa');
  const b = conn('cB', 'pb');
  await a.say({ type: 'world_info', sceneId: DEFAULT_SCENE });
  await b.say({ type: 'world_info', sceneId: DEFAULT_SCENE });
  b.sent.length = 0;

  await a.say({ type: 'wish_refine', itemRef: 'buddy', newSize: 'medium' }); // big→medium=变小=对

  const ch = store.getCharacter('w1', 'buddy')!;
  assert.equal(ch.appearance.size, 'medium', '体型改为 medium');
  assert.equal(ch.appearance.scale, sizeToScale('medium'), 'scale 同步 1.0');
  const resized = b.ofType('character_resized');
  assert.equal(resized.length, 1, '同场景的 B 收到 character_resized');
  assert.equal(resized[0]['characterId'], 'buddy');
  assert.equal(resized[0]['size'], 'medium');
  assert.equal(resized[0]['scale'], sizeToScale('medium'));
  assert.ok(a.ofType('task_complete').length === 1, '方向对 → 盖章');
});

test('WS wish_refine（造物）：改 def.spec.scale + terrain_patch 携带更新后的 def（只改倍率不换资产）', async () => {
  const { store, conn } = rig();
  // village 场景带矩阵，(10,10) 摆一件造物 prop-1（big，spec.scale=1.4）。
  store.upsertScene({
    worldId: 'w1', sceneId: DEFAULT_SCENE, name: '村庄', terrainAsset: 'h',
    gridTiles: G, terrainVersion: 1, pois: [], portals: [],
  });
  const spec = { ...fallbackSdfPropSpec('小车'), scale: sizeToScale('big') };
  const def = creationItemDef('w1', 'prop-1', spec);
  store.upsertItem(def);
  const t = emptyTerrain();
  t.palette = ['prop-1'];
  t.itemRef[10 * G + 10] = 1;
  store.setSceneTerrain('w1', DEFAULT_SCENE, encodeTerrain(t), 1);
  store.setActiveTask('w1', 'pa', {
    id: 't2', type: 'wish', npcId: 'npc1', npcName: '小兔', stampStyle: 'smile',
    wishAbility: 'create_prop', wishStage: 'tried', refineItemRef: 'prop-1',
    refineDir: 'smaller', refineFromSize: 'big', refineTries: 0,
  });
  const a = conn('cA', 'pa');
  await a.say({ type: 'world_info', sceneId: DEFAULT_SCENE });
  a.sent.length = 0;

  await a.say({ type: 'wish_refine', itemRef: 'prop-1', newSize: 'medium' }); // big→medium=变小=对

  const scale = (store.getItemDef('w1', 'prop-1')!.spec as { scale: number }).scale;
  assert.equal(scale, sizeToScale('medium'), 'def.spec.scale 改成 1.0');
  const patch = a.ofType('terrain_patch');
  assert.ok(patch.length >= 1, '发 terrain_patch 触发重渲染');
  const items = (patch[patch.length - 1]['items'] as { id: string; spec: { scale: number }; renderRef: string }[]);
  const carried = items.find((d) => d.id === 'prop-1');
  assert.ok(carried, 'patch.items 强制携带更新后的 def');
  assert.equal(carried!.spec.scale, sizeToScale('medium'), '客户端收到的 def 是新 scale');
  assert.equal(carried!.renderRef, 'sdf_inline', '仍是同一造物、不换资产哈希（renderRef 不变）');
  assert.ok(a.ofType('task_complete').length === 1, '方向对 → 盖章');
});
