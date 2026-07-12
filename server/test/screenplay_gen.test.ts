// 剧本生成层（realtime-primitives P5）：口语「我们来踢球吧」→ 生成【真 TS】剧本 → 过 typecheck → 开演。
// 覆盖三大关键（老板明确交代）：①强模型分离 ②typecheck 关 + 失败带错回喂重生成 ③生成真 TS 非自造 DSL。
// 生成层与模型无关，重试环用假 draftFn 单测；cast→演员映射复用 stage_debut 的选角契约。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkScreenplay } from '../src/screenplay_check.ts';
import {
  buildGenSystem,
  buildStageOptsFromDraft,
  generateScreenplayWithRetry,
  parseDraft,
  type DraftFn,
} from '../src/screenplay_gen.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { respondToTranscript } from '../src/voice.ts';
import { WorldStore } from '../src/persistence.ts';
import { WorldHub } from '../src/world_hub.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, effectiveAbilities, type Character, type Player, type ScreenplayGenContext } from '../src/types.ts';

// ── 测试脚手架（复用 stage_debut.test 的选角种子形状）─────────────────────────
function seedChar(store: WorldStore, id: string, name: string, isFairy = false, abilities: string[] = []): void {
  const c: Character = {
    id, worldId: 'w1', isFairy, name, personality: 'p', voiceId: `voice-${id}`,
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId: DEFAULT_SCENE, abilities, relationships: {},
  };
  store.addCharacter(c);
}

/** 世界：仙子（带 play_game 能力）+ n 个村民。 */
function seedWorld(names = ['阿花', '阿牛', '阿土']): WorldStore {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'f1', '小仙子', true, ['create_character', 'create_prop', 'create_sticker', 'play_game']);
  names.forEach((n, i) => seedChar(store, `c${i + 1}`, n));
  return store;
}

function joinKid(hub: WorldHub, playerId: string): void {
  hub.join('w1', { clientId: `conn-${playerId}`, playerId, sceneId: DEFAULT_SCENE, send: () => {}, sendText: () => {}, posBin: false, sendBin: () => {} });
}

const CTX: ScreenplayGenContext = { gameDesc: '踢球', villagerNames: ['阿花', '阿牛'], hasPlayer: true };

// 一段【故意用错 SDK】的剧本（moveTo 收 Spot 不收数字）——过不了 typecheck，用来驱动重试环。
const BAD_CODE = `const a = stage.actors[0];\nawait a.moveTo(42);`;
// 一段合法的最小剧本。
const GOOD_CODE = `await stage.narrate('我们来玩吧！');\nstage.end({ winner: '大家', praise: '真棒！' });`;

function draftJson(code: string, cast: string[] = []): string {
  return JSON.stringify({ cast, code });
}

// ── ① system prompt 带全部把关材料（契约 + 防腐纪律 + few-shot）──────────────
test('生成 prompt 带上接口契约、防腐纪律与两个 few-shot 样例', () => {
  const sys = buildGenSystem();
  assert.match(sys, /interface Stage/); // stage_sdk.d.ts 契约拼进来了
  assert.match(sys, /防腐纪律/);
  assert.match(sys, /if \(game === 'soccer'\)/); // 明确禁止玩法名判断
  assert.match(sys, /spawnBall/); // 踢球样例
  assert.match(sys, /老鹰抓小鸡/); // 纯复用样例
  assert.match(sys, /"cast"/); // 输出格式
});

// ── ② parseDraft ────────────────────────────────────────────────────────────
test('parseDraft：解析 {cast,code}，容忍 ```json 围栏', () => {
  const d = parseDraft('```json\n' + draftJson('await stage.narrate("hi");', ['老鹰']) + '\n```');
  assert.ok(d);
  assert.equal(d.cast[0], '老鹰');
  assert.match(d.code, /narrate/);
});

test('parseDraft：code 缺失/空/非 JSON → null', () => {
  assert.equal(parseDraft('{"cast":[]}'), null);
  assert.equal(parseDraft('{"code":"  "}'), null);
  assert.equal(parseDraft('not json'), null);
});

// ── ③ 重试环：typecheck 失败 → 带错回喂重生成 ───────────────────────────────
test('重试环：首个草案过不了 typecheck，回喂错误后第二次生成通过', async () => {
  const seen: string[] = [];
  let call = 0;
  const draftFn: DraftFn = async (messages) => {
    call++;
    // 记下每次调用时对话最后一条 user 的内容（重试时应带上编译诊断）
    seen.push(messages[messages.length - 1].content);
    return call === 1 ? draftJson(BAD_CODE) : draftJson(GOOD_CODE);
  };
  const draft = await generateScreenplayWithRetry(draftFn, CTX);
  assert.ok(draft, '第二次应过关');
  assert.match(draft.code, /narrate/);
  assert.equal(call, 2, '恰好重试一次');
  // 第二次调用的最后一条 user 必须是「带诊断的修正要求」，且诊断里含类型错误关键词
  assert.match(seen[1], /没通过类型检查/);
  assert.match(seen[1], /number/);
});

test('重试环：始终过不了 typecheck → 用尽次数返回 null', async () => {
  let call = 0;
  const draftFn: DraftFn = async () => { call++; return draftJson(BAD_CODE); };
  const draft = await generateScreenplayWithRetry(draftFn, CTX, 3);
  assert.equal(draft, null);
  assert.equal(call, 3, '尝试满 3 次');
});

test('重试环：首次即合法 → 只调一次直接返回', async () => {
  let call = 0;
  const draftFn: DraftFn = async () => { call++; return draftJson(GOOD_CODE, []); };
  const draft = await generateScreenplayWithRetry(draftFn, CTX);
  assert.ok(draft);
  assert.equal(call, 1);
});

test('重试环：模型调用抛错（超时/网络）→ 不重试同一条，返回 null', async () => {
  let call = 0;
  const draftFn: DraftFn = async () => { call++; throw new Error('timeout'); };
  const draft = await generateScreenplayWithRetry(draftFn, CTX);
  assert.equal(draft, null);
  assert.equal(call, 1, '调用失败不重试');
});

test('重试环：解析不出 JSON 也算一次尝试并回喂纠正要求', async () => {
  let call = 0;
  const draftFn: DraftFn = async (messages) => {
    call++;
    if (call === 1) return '我给你写好了：（一堆散文，没有 JSON）';
    // 第二次应看到「解析不出」的纠正提示
    assert.match(messages[messages.length - 1].content, /解析不出/);
    return draftJson(GOOD_CODE);
  };
  const draft = await generateScreenplayWithRetry(draftFn, CTX);
  assert.ok(draft);
  assert.equal(call, 2);
});

// ── ④ mock 适配器的 generateScreenplay 产物必须真过 typecheck（回归护栏）──────
test('mock generateScreenplay：踢球变体过 typecheck', async () => {
  const { llm } = createMockAdapters();
  const d = await llm.generateScreenplay({ gameDesc: '踢球', villagerNames: [], hasPlayer: true });
  assert.ok(d);
  assert.deepEqual(checkScreenplay(d.code), [], '踢球剧本必须过类型检查');
  assert.match(d.code, /spawnBall/);
});

test('mock generateScreenplay：非球类变体过 typecheck', async () => {
  const { llm } = createMockAdapters();
  const d = await llm.generateScreenplay({ gameDesc: '捉迷藏', villagerNames: ['阿花'], hasPlayer: false });
  assert.ok(d);
  assert.deepEqual(checkScreenplay(d.code), [], '非球类剧本必须过类型检查');
});

// ── ⑤ cast → 真实演员映射（复用 stage_debut 选角契约）────────────────────────
test('buildStageOptsFromDraft：cast 有序映射到村民（改名为角色名，id/音色留本人）+ 追加玩家', () => {
  const store = seedWorld(['阿花', '阿牛', '阿土']);
  store.upsertPlayer({ id: 'p1', name: '王小明', nickname: '明明', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' } as Player);
  const hub = new WorldHub();
  joinKid(hub, 'p1');
  const r = buildStageOptsFromDraft({ code: GOOD_CODE, cast: ['老鹰', '母鸡'] }, store, hub, 'w1', 'p1');
  assert.ok(r.ok);
  assert.deepEqual(r.opts.actors, [
    { id: 'c1', name: '老鹰', isPlayer: false, voiceId: 'voice-c1' }, // 阿花→老鹰，id/音色仍是本人
    { id: 'c2', name: '母鸡', isPlayer: false, voiceId: 'voice-c2' },
    { id: 'p1', name: '明明', isPlayer: true },                        // 玩家优先小名
  ]);
  assert.equal(r.opts.code, GOOD_CODE);
});

test('buildStageOptsFromDraft：空 cast（踢球）+ 有玩家 → 只有玩家演员', () => {
  const store = seedWorld([]);
  const hub = new WorldHub();
  joinKid(hub, 'p1');
  const r = buildStageOptsFromDraft({ code: GOOD_CODE, cast: [] }, store, hub, 'w1', 'p1');
  assert.ok(r.ok);
  assert.deepEqual(r.opts.actors, [{ id: 'p1', name: '小朋友', isPlayer: true }]); // 无档案→「小朋友」
});

test('buildStageOptsFromDraft：cast 比可用村民多 → 人不够，不开演', () => {
  const store = seedWorld(['阿花']); // 只有 1 个村民
  const hub = new WorldHub();
  joinKid(hub, 'p1');
  const r = buildStageOptsFromDraft({ code: GOOD_CODE, cast: ['老鹰', '母鸡', '小鸡'] }, store, hub, 'w1', 'p1');
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /小伙伴/);
});

test('buildStageOptsFromDraft：空 cast + 没玩家在场 → 没人可演', () => {
  const store = seedWorld([]);
  const r = buildStageOptsFromDraft({ code: GOOD_CODE, cast: [] }, store, new WorldHub(), 'w1', 'p-absent');
  assert.equal(r.ok, false);
});

// ── ⑥ 意图路由：只有小仙子（有 play_game 能力）认「玩游戏」，普通村民不认 ──────
test('routeIntent(mock)：小仙子把「我们来踢球吧」路由成 play_game 指令', async () => {
  const { llm } = createMockAdapters();
  const intent = await llm.routeIntent('我们来踢球吧', {
    characterName: '小仙子', personality: 'p',
    abilities: ['do_action', 'create_character', 'play_game'],
  });
  assert.equal(intent.kind, 'command');
  assert.equal(intent.behaviorScript?.commands[0].type, 'play_game');
  assert.equal(intent.behaviorScript?.commands[0].params.game, '我们来踢球吧');
});

test('routeIntent(mock)：普通村民（无 play_game 能力）不会开游戏', async () => {
  const { llm } = createMockAdapters();
  const intent = await llm.routeIntent('我们来踢球吧', {
    characterName: '阿花', personality: 'p',
    abilities: ['do_action', 'move_to'],
  });
  assert.notEqual(intent.behaviorScript?.commands[0]?.type, 'play_game');
});

// ── ⑦ 端到端摘取：respondToTranscript 把 play_game 摘成 response.gameRequest ──
test('respondToTranscript：对小仙子说「玩老鹰抓小鸡」→ response.gameRequest 被摘出、不下发普通指令', async () => {
  const store = seedWorld();
  const adapters = createMockAdapters();
  // 仙子的 effectiveAbilities 必须含 play_game（否则 mock routeIntent 不触发）
  const fairy = store.getCharacter('w1', 'f1')!;
  assert.ok(effectiveAbilities(fairy).includes('play_game'), '仙子应有 play_game 能力');
  const resp = await respondToTranscript('w1', 'f1', 'p1', '我们来玩老鹰抓小鸡', adapters, store);
  assert.equal(resp.gameRequest, '我们来玩老鹰抓小鸡');
  assert.equal(resp.behaviorScript, undefined, 'play_game 被摘走后不应再下发 behaviorScript');
});
