// P8：两个手写剧本跑端到端——WS 舞台协议 + 双连接 + 服务端 near 求值 + 造物管线。
// 同时把命令流录成 golden(test/fixtures/screenplay_cmds.json)，交 Godot 侧 test_screenplay_replay.gd
// 回放进 StageAgent，验证客户端认得服务端会发的每一条命令。
// 改了剧本 → UPDATE_GOLDEN=1 npm test 重录。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { WorldHub } from '../src/world_hub.ts';
import { StageDirector } from '../src/stage_session.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { loadScreenplay } from '../src/screenplays.ts';
import type { StageActorInfo, StagePropMaker } from '../src/stage_types.ts';

const GOLDEN = new URL('../../test/fixtures/screenplay_cmds.json', import.meta.url);

type Msg = { type: string; [k: string]: unknown };
type Conn = ReturnType<ReturnType<typeof rig>['conn']>;

/** 两个客户端可进同一个世界的测试台（与 stage_session.test.ts 同型）。 */
function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(1000, 1000);
  const hub = new WorldHub();
  let propN = 0;
  const maker: StagePropMaker = async (_worldId, desc) => ({ id: `prop-${++propN}`, spec: { desc } });
  const stages = new StageDirector(hub, maker);
  const conn = (connKey: string) => {
    const sent: Msg[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s) as Msg) };
    const session = newVoiceSession();
    const say = (msg: Record<string, unknown>) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub, stages);
    return {
      sent,
      say,
      ofType: (t: string) => sent.filter((m) => m.type === t),
      /** 服务端下发的、需要回执的命令（watch/unwatch 的 cmdId=-1 不算）。 */
      cmds: () => sent.filter((m) => m.type === 'stage_cmd' && (m.cmdId as number) > 0),
      ack: (cmdId: number, result?: Record<string, unknown>) =>
        say({ type: 'stage_event', kind: 'ack', cmdId, ...(result ? { result } : {}) }),
    };
  };
  return { hub, stages, conn };
}

async function waitFor(pred: () => boolean, ms = 3000): Promise<void> {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > ms) throw new Error('waitFor 超时');
    await new Promise((r) => setTimeout(r, 2));
  }
}

/** 完成型命令的回执负载：prop_spawn 要把道具 id 带回脚本。 */
function resultFor(m: Msg): Record<string, unknown> | undefined {
  if (m.op === 'prop_spawn') return { id: (m.args as Record<string, unknown>).id as string };
  return undefined;
}

/** 傻瓜客户端：见一条 stage_cmd 就回执（多连接时首个生效，后来的被服务端安静忽略）。 */
function autoAck(c: Conn): () => void {
  const seen = new Set<number>();
  const h = setInterval(() => {
    for (const m of c.cmds()) {
      const id = m.cmdId as number;
      if (seen.has(id)) continue;
      seen.add(id);
      void c.ack(id, resultFor(m));
    }
  }, 2);
  return () => clearInterval(h);
}

/** 录进 golden 的命令：去掉 stageId 和每次都变的服务端时戳。 */
function normalize(m: Msg): Record<string, unknown> {
  const args = { ...(m.args as Record<string, unknown>) };
  delete args.serverStartMs;
  return { cmdId: m.cmdId, ...(m.actorId ? { actorId: m.actorId } : {}), op: m.op, args };
}

const recorded: Record<string, { actors: StageActorInfo[]; cmds: Record<string, unknown>[] }> = {};

function record(name: string, actors: StageActorInfo[], c: Conn): void {
  recorded[name] = { actors, cmds: c.ofType('stage_cmd').map(normalize) };
}

// ---------------------------------------------------------------------------

const HIDE_ACTORS: StageActorInfo[] = [
  { id: 'a1', name: '小灰狼', isPlayer: false, voiceId: 'zh-CN-YunxiaNeural' },
  { id: 'p1', name: '宝宝', isPlayer: true },
];

test('躲猫猫: 双连接开演 → 服务端 near 判定抓到 → 换鬼(flee) → 再抓到 → HUD 计分/收场', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'p2' });
  const stopA = autoAck(a);
  const stopB = autoAck(b); // 两端都回执：验证首个 ack 生效、次个被忽略而不炸

  const done = stages.startStage('w1', {
    code: loadScreenplay('hide_and_seek'),
    actors: HIDE_ACTORS,
    params: { hideSec: 0.02, gameSec: 60, catchDist: 2 },
  });
  assert.ok(done);

  // 开场：两端都进入观演状态
  await waitFor(() => a.ofType('stage_begin').length === 1 && b.ofType('stage_begin').length === 1);
  await waitFor(() => a.cmds().some((m) => m.op === 'hud_countdown'));
  const cd = a.cmds().find((m) => m.op === 'hud_countdown')!;
  assert.equal((cd.args as Record<string, unknown>).sec, 60);
  assert.ok(typeof (cd.args as Record<string, unknown>).serverStartMs === 'number', '倒计时带服务端起始时戳对齐双端');

  // 第一轮：先布 near 判定，再下 follow —— 见到 follow 广播即证明订阅已在服务端登记
  await waitFor(() => a.cmds().some((m) => m.op === 'follow'));
  const follow = a.cmds().find((m) => m.op === 'follow')!;
  assert.equal(follow.actorId, 'a1');
  assert.deepEqual(follow.args, { target: 'p1' });
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'near'), false,
    'near 走服务端求值，不下发客户端探测器');

  // 位置流喂进来：还很远，不算抓到
  stages.updatePositions('w1', [{ id: 'a1', x: 0, y: 0 }, { id: 'p1', x: 50, y: 0 }]);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(a.cmds().some((m) => m.op === 'hud_score_add'), false, '还没追上，不该计分');

  // 追上了（dist=1 ≤ 2）：脚本 await 的 once('near') 兑现 → 计分 + 换鬼提示
  stages.updatePositions('w1', [{ id: 'p1', x: 1, y: 0 }]);
  await waitFor(() => a.cmds().some((m) => m.op === 'hud_toast'));
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score_add').length, 1);
  assert.match(String((a.cmds().find((m) => m.op === 'hud_toast')!.args as Record<string, unknown>).text), /抓到/);

  // 第二轮换鬼：鬼开始逃（先布判定，见到 flee 即证明第二个 near 已登记）
  await waitFor(() => a.cmds().some((m) => m.op === 'flee'));
  const flee = a.cmds().find((m) => m.op === 'flee')!;
  assert.equal(flee.actorId, 'a1');
  assert.deepEqual(flee.args, { target: 'p1' });

  // 逃开（复位边沿）再被追上 → 第二次计分 → 撤倒计时 → 收场
  stages.updatePositions('w1', [{ id: 'a1', x: 0, y: 0 }, { id: 'p1', x: 50, y: 0 }]);
  stages.updatePositions('w1', [{ id: 'p1', x: 1, y: 0 }]);

  const r = await done!;
  stopA();
  stopB();
  assert.equal(r.status, 'done');
  const res = r.status === 'done' ? r.result : undefined;
  assert.equal(res?.winner, '宝宝');
  assert.match(String(res?.praise), /抓到小灰狼/);

  // HUD 与设置型命令的完整轨迹
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score_add').length, 2, '两轮各计一分');
  assert.equal(a.cmds().filter((m) => m.op === 'stop').length, 2, '每轮抓到都要停下 follow/flee');
  assert.equal(a.cmds().some((m) => m.op === 'hud_cancel'), true, '收场前撤掉倒计时');
  assert.equal(a.cmds().filter((m) => m.op === 'narrate').length, 3);
  // 倒计时的 timer 订阅确实下发给了客户端（对比 near）
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer'), true);
  // 收场广播给两端
  assert.deepEqual(a.ofType('stage_end')[0]?.result, res);
  assert.deepEqual(b.ofType('stage_end')[0]?.result, res);
  assert.equal(stages.activeIn('w1'), false);

  record('hide_and_seek', HIDE_ACTORS, a);
});

test('躲猫猫: 倒计时归零(没被抓到) → 小朋友获胜收场', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);
  const done = stages.startStage('w1', {
    code: loadScreenplay('hide_and_seek'),
    actors: HIDE_ACTORS,
    params: { hideSec: 0.02, gameSec: 60, catchDist: 2 },
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer'));
  const watch = a.ofType('stage_cmd').find((m) => m.op === 'watch')!;
  const subId = (watch.args as Record<string, unknown>).subId as string;
  // 从没喂过位置 → 一直没抓到；客户端倒计时归零上行
  await a.say({ type: 'stage_event', kind: 'timer', subId });
  const r = await done!;
  stop();
  assert.equal(r.status, 'done');
  const res = r.status === 'done' ? r.result : undefined;
  assert.equal(res?.winner, '宝宝');
  assert.match(String(res?.praise), /藏得真好/);
  assert.equal(a.cmds().some((m) => m.op === 'hud_score_add'), false, '一分没得');
});

test('躲猫猫: 缺省 params 也能跑（不注入旋钮时脚本自带默认值）', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);
  const done = stages.startStage('w1', { code: loadScreenplay('hide_and_seek'), actors: HIDE_ACTORS });
  await waitFor(() => a.cmds().some((m) => m.op === 'hud_countdown'));
  assert.equal((a.cmds().find((m) => m.op === 'hud_countdown')!.args as Record<string, unknown>).sec, 60, '默认一局 60 秒');
  stages.handleStageEvent('w1', { kind: 'abort' }); // 默认藏身 10 秒，不等它
  await done!;
  stop();
});

// ---------------------------------------------------------------------------

const PLAY_ACTORS: StageActorInfo[] = [
  { id: 'c1', name: '丑小鸭', isPlayer: false, voiceId: 'zh-CN-YunxiaNeural' },
  { id: 'c2', name: '鸭妈妈', isPlayer: false, voiceId: 'zh-CN-XiaoxiaoNeural' },
  { id: 'c3', name: '天鹅', isPlayer: false, voiceId: 'zh-CN-XiaoyiNeural' },
];

test('三幕小剧场: 命令按幕逐条推进，Promise.all 走位并行下发，全程不等造物管线', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });

  const done = stages.startStage('w1', {
    code: loadScreenplay('three_act_play'),
    actors: PLAY_ACTORS,
    params: { pond: 'pond', lake: 'lake' },
  });
  assert.ok(done);

  let acked = 0;
  /**
   * 走一批命令：等到恰好这几条在途 → 校验 op/actorId 顺序 → 全部回执放行。
   * 「恰好」是关键断言：await 型命令没回执前脚本不许再发命令，
   * 所以一批里出现两条 move_to 就等于证明了 Promise.all 的并行下发。
   */
  async function step(label: string, ...expect: [string, string?][]): Promise<Msg[]> {
    await waitFor(() => a.cmds().length >= acked + expect.length, 3000);
    const batch = a.cmds().slice(acked, acked + expect.length);
    assert.deepEqual(batch.map((m) => [m.op, m.actorId]), expect.map(([op, id]) => [op, id]), label);
    assert.equal(a.cmds().length, acked + expect.length, `${label}: 不该有额外命令在途`);
    acked += expect.length;
    for (const m of batch) await a.ack(m.cmdId as number, resultFor(m));
    return batch;
  }

  // 第一幕
  const act1 = await step('第一幕开场', ['camera'], ['banner'], ['narrate']);
  assert.equal((act1[0].args as Record<string, unknown>).mode, 'overview');
  assert.match(String((act1[1].args as Record<string, unknown>).text), /第一幕/);
  assert.match(String((act1[2].args as Record<string, unknown>).text), /鸭妈妈一家/);

  const walk = await step('并行走位: 丑小鸭与鸭妈妈同时出发', ['move_to', 'c1'], ['move_to', 'c2']);
  assert.deepEqual(walk.map((m) => (m.args as Record<string, unknown>).target), ['pond', 'pond']);

  const line1 = await step('鸭妈妈开口', ['say', 'c2']);
  assert.equal((line1[0].args as Record<string, unknown>).action, 'wave');

  // 第二幕
  await step('第二幕开场', ['banner'], ['narrate']);
  const act2 = await step('对话运镜 + 丑小鸭的委屈', ['camera'], ['say', 'c1']);
  assert.equal((act2[0].args as Record<string, unknown>).mode, 'dialog');
  assert.equal((act2[1].args as Record<string, unknown>).action, 'cry');
  await step('鸭妈妈安慰', ['say', 'c2']);

  // 第三幕
  await step('第三幕开场', ['banner'], ['narrate']);
  await step('并行走位: 丑小鸭与天鹅同赴湖边', ['move_to', 'c1'], ['move_to', 'c3']);
  await step('天鹅点破', ['say', 'c3']);
  const spin = await step('丑小鸭转个圈', ['do_action', 'c1']);
  assert.equal((spin[0].args as Record<string, unknown>).action, 'spin');

  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(r.status === 'done' ? r.result : undefined, { praise: '演得真棒！' });
  // 收场前最后一条是复位运镜（脚本 fire-and-forget，不等回执）
  const last = a.cmds().at(-1)!;
  assert.equal(last.op, 'camera');
  assert.equal((last.args as Record<string, unknown>).mode, 'reset');
  assert.equal(a.cmds().filter((m) => m.op === 'narrate').length, 3, '三幕三段旁白');
  assert.equal(a.cmds().filter((m) => m.op === 'move_to').length, 4);
  // 造物要真跑一趟 LLM+生图，几十秒卡在幕中间；剧本刻意不碰它（原语覆盖见下一条测试）
  assert.equal(a.cmds().some((m) => m.op === 'prop_spawn'), false, '演出全程不等造物管线');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { praise: '演得真棒！' });

  record('three_act_play', PLAY_ACTORS, a);
});

test('道具原语: create 走服务端造物出 spec → 客户端只收 prop_spawn；place/remove 直接下发', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);
  const done = stages.startStage('w1', {
    code: `
      const egg = await stage.prop.create('一颗大大的蛋', stage.actors[1]);
      await stage.prop.place(egg.id, 'lake');
      stage.prop.remove(egg.id);
      stage.end({ pid: egg.id });
    `,
    actors: PLAY_ACTORS,
  });
  const r = await done!;
  stop();
  assert.equal(r.status, 'done');
  assert.deepEqual(r.status === 'done' ? r.result : undefined, { pid: 'prop-1' });

  const spawn = a.cmds().find((m) => m.op === 'prop_spawn')!;
  assert.equal(a.cmds().some((m) => m.op === 'prop_create'), false, '客户端造不出 spec，从不收 prop_create');
  assert.deepEqual((spawn.args as Record<string, unknown>).spec, { desc: '一颗大大的蛋' });
  assert.equal((spawn.args as Record<string, unknown>).near, 'c2', '道具落在指定演员身边');
  assert.deepEqual(a.cmds().find((m) => m.op === 'prop_place')!.args, { id: 'prop-1', at: 'lake' });
  assert.deepEqual(a.cmds().find((m) => m.op === 'prop_remove')!.args, { id: 'prop-1' });
});

test('三幕小剧场: 选角名字对不上 → 脚本抛错 → 广播 stage_abort', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: loadScreenplay('three_act_play'),
    actors: [{ id: 'c1', name: '大灰狼', isPlayer: false }],
  });
  const r = await done!;
  assert.equal(r.status, 'error');
  assert.match(r.status === 'error' ? r.message : '', /找不到角色: 丑小鸭/);
  assert.match(String(a.ofType('stage_abort')[0]?.reason), /找不到角色/);
});

// ---------------------------------------------------------------------------

const SOCCER_ACTORS: StageActorInfo[] = [
  { id: 'p1', name: '宝宝', isPlayer: true },
];

test('踢球: spawnBall → 划两侧球门 → 球进门(服务端 enter 判定)计分/复位 → 先到分获胜收场', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);

  const done = stages.startStage('w1', {
    code: loadScreenplay('soccer'),
    actors: SOCCER_ACTORS,
    params: {
      center: { x: 75, y: 75 },
      goalRed: { x: 20, y: 75, r: 6 },
      goalBlue: { x: 130, y: 75, r: 6 },
      gameSec: 120,
      winScore: 2,
    },
  });
  assert.ok(done);

  // 开局：生成球（完成型，worker 分配 id=ball1）+ 倒计时。球走服务端 enter 判定，不下发客户端探测器。
  await waitFor(() => a.cmds().some((m) => m.op === 'spawn_ball'));
  const spawn = a.cmds().find((m) => m.op === 'spawn_ball')!;
  assert.equal((spawn.args as Record<string, unknown>).id, 'ball1', '球 id 由 worker 分配');
  await waitFor(() => a.cmds().some((m) => m.op === 'hud_countdown'));
  assert.equal((a.cmds().find((m) => m.op === 'hud_countdown')!.args as Record<string, unknown>).sec, 120);
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'enter'), false,
    'enter(球门)走服务端求值，不下发客户端探测器');

  // 第一颗球滚进蓝队门(130,75) → 红队得 1 分 → 复位回中场(ball_reset)。
  stages.updatePositions('w1', [{ id: 'ball1', x: 130, y: 75 }]);
  await waitFor(() => a.cmds().some((m) => m.op === 'hud_toast'));
  assert.match(String((a.cmds().find((m) => m.op === 'hud_toast')!.args as Record<string, unknown>).text), /红队进球/);
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score_add').length, 1, '进一个球计一分');
  await waitFor(() => a.cmds().some((m) => m.op === 'ball_reset'));

  // 球离开球门(回中场)→ 再进蓝队门 → 红队第 2 分 = winScore → 获胜收场。
  stages.updatePositions('w1', [{ id: 'ball1', x: 75, y: 75 }]);
  stages.updatePositions('w1', [{ id: 'ball1', x: 130, y: 75 }]);

  const r = await done!;
  stop();
  assert.equal(r.status, 'done');
  const res = r.status === 'done' ? r.result : undefined;
  assert.equal(res?.winner, '红队');
  assert.equal(res?.red, 2);
  assert.equal(res?.blue, 0);
  assert.match(String(res?.praise), /红队赢啦/);
  // 两个计分板各建一次；先到分那球不复位（游戏已结束），故只复位一次
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score').length, 2, '红蓝两队各一块计分板');
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score_add').length, 2, '两粒进球各计一分');
  assert.equal(a.cmds().filter((m) => m.op === 'ball_reset').length, 1, '只有非获胜球才复位');
  assert.equal(a.cmds().some((m) => m.op === 'hud_cancel'), true, '收场前撤倒计时');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, res);
  assert.equal(stages.activeIn('w1'), false);

  record('soccer', SOCCER_ACTORS, a);
});

test('踢球: 时间到平局也能收场（一球没进）', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);
  const done = stages.startStage('w1', { code: loadScreenplay('soccer'), actors: SOCCER_ACTORS, params: { gameSec: 60 } });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer'));
  const watch = a.ofType('stage_cmd').find((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer')!;
  await a.say({ type: 'stage_event', kind: 'timer', subId: (watch.args as Record<string, unknown>).subId as string });
  const r = await done!;
  stop();
  assert.equal(r.status, 'done');
  const res = r.status === 'done' ? r.result : undefined;
  assert.equal(res?.winner, '平局');
  assert.match(String(res?.praise), /平局/);
  assert.equal(a.cmds().some((m) => m.op === 'hud_score_add'), false, '一球没进');
});

// ---------------------------------------------------------------------------

const EAGLE_ACTORS: StageActorInfo[] = [
  { id: 'a1', name: '老鹰', isPlayer: false, voiceId: 'zh-CN-YunxiaNeural' },
  { id: 'a2', name: '母鸡', isPlayer: false, voiceId: 'zh-CN-XiaoxiaoNeural' },
  { id: 'a3', name: '小鸡甲', isPlayer: false, voiceId: 'zh-CN-XiaoyiNeural' },
  { id: 'a4', name: '小鸡乙', isPlayer: false, voiceId: 'zh-CN-XiaoyiNeural' },
  { id: 'p1', name: '宝宝', isPlayer: true },
];

test('老鹰抓小鸡: 链式 follow + 鹰追队尾 → near 抓捕(服务端判定)逐只出局 → 抓光收场（纯脚本复用现有原语）', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const stop = autoAck(a);

  const done = stages.startStage('w1', {
    code: loadScreenplay('eagle_and_chicks'),
    actors: EAGLE_ACTORS,
    params: { catchDist: 2 },
  });
  assert.ok(done);

  // 链式跟随：母鸡跟小朋友、小鸡一个跟一个、鹰追队尾(小鸡乙 a4)。全是现有 follow，无新原语。
  await waitFor(() => a.cmds().filter((m) => m.op === 'follow').length >= 4);
  const follows = a.cmds().filter((m) => m.op === 'follow');
  assert.deepEqual(follows.slice(0, 4).map((m) => [m.actorId, (m.args as Record<string, unknown>).target]), [
    ['a2', 'p1'], // 母鸡跟小朋友
    ['a3', 'a2'], // 小鸡甲跟母鸡
    ['a4', 'a3'], // 小鸡乙跟小鸡甲
    ['a1', 'a4'], // 老鹰追队尾（小鸡乙）
  ]);
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'near'), false,
    'near 抓捕走服务端求值，不下发客户端探测器');

  // 鹰追上队尾小鸡乙(a4) → 抓到出局 → 改追新队尾小鸡甲(a3)
  stages.updatePositions('w1', [{ id: 'a1', x: 0, y: 0 }, { id: 'a4', x: 50, y: 0 }]);
  stages.updatePositions('w1', [{ id: 'a1', x: 49, y: 0 }]); // dist=1 ≤ 2 → 抓到 a4
  await waitFor(() => a.cmds().filter((m) => m.op === 'follow').length >= 5);
  const retarget = a.cmds().filter((m) => m.op === 'follow')[4];
  assert.deepEqual([retarget.actorId, (retarget.args as Record<string, unknown>).target], ['a1', 'a3'], '鹰改追新队尾小鸡甲');
  assert.match(String((a.cmds().find((m) => m.op === 'hud_toast')!.args as Record<string, unknown>).text), /小鸡乙被抓住/);

  // 鹰追上小鸡甲(a3) → 抓光 → 收场
  stages.updatePositions('w1', [{ id: 'a3', x: 10, y: 0 }, { id: 'a1', x: 80, y: 0 }]);
  stages.updatePositions('w1', [{ id: 'a1', x: 11, y: 0 }]); // dist=1 → 抓到 a3

  const r = await done!;
  stop();
  assert.equal(r.status, 'done');
  const res = r.status === 'done' ? r.result : undefined;
  assert.equal(res?.winner, '老鹰');
  assert.equal(res?.caught, 2);
  assert.match(String(res?.praise), /小鸡都被抓住/);
  assert.equal(a.cmds().filter((m) => m.op === 'follow').length, 5, '链式 4 条 + 抓掉一只后重定向 1 条');
  assert.equal(a.cmds().filter((m) => m.op === 'stop').length, 4, '每抓一只：鹰停 + 该小鸡停');
  assert.equal(a.cmds().filter((m) => m.op === 'hud_score_add').length, 2, '抓到两只各计一分');
  assert.equal(a.cmds().filter((m) => m.op === 'hud_toast').length, 2);
  assert.equal(a.cmds().some((m) => m.op === 'spawn_ball'), false, '纯追逐玩法不需要球原语');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, res);

  record('eagle_and_chicks', EAGLE_ACTORS, a);
});

// ---------------------------------------------------------------------------

test('golden: 命令流与 test/fixtures/screenplay_cmds.json 一致（Godot 侧回放同一份）', () => {
  assert.deepEqual(Object.keys(recorded).sort(), ['eagle_and_chicks', 'hide_and_seek', 'soccer', 'three_act_play'], '四个剧本都录到了');
  const json = `${JSON.stringify(recorded, null, 2)}\n`;
  if (process.env.UPDATE_GOLDEN === '1') {
    mkdirSync(new URL('.', GOLDEN), { recursive: true });
    writeFileSync(GOLDEN, json);
    return;
  }
  assert.ok(existsSync(GOLDEN), '缺 golden 文件，先跑 UPDATE_GOLDEN=1 npm test 重录');
  const want = readFileSync(GOLDEN, 'utf8');
  assert.deepEqual(JSON.parse(json), JSON.parse(want), '剧本改了？跑 UPDATE_GOLDEN=1 npm test 重录 golden');
});
