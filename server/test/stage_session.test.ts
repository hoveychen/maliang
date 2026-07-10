import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldHub } from '../src/world_hub.ts';
import { StageDirector } from '../src/stage_session.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';

const ACTORS = [
  { id: 'a1', name: '小鸭', isPlayer: false },
  { id: 'p1', name: '宝宝', isPlayer: true },
];

/** 两个客户端已进 w1 的测试台。 */
import type { StagePropMaker } from '../src/stage_types.ts';

function rig(propMaker?: StagePropMaker) {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const stages = new StageDirector(hub, propMaker);
  const conn = (connKey: string) => {
    const sent: { type: string; [k: string]: unknown }[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: Record<string, unknown>) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub, stages);
    return { sent, say, ofType: (t: string) => sent.filter((m) => m.type === t) };
  };
  return { hub, stages, conn };
}

async function waitFor(pred: () => boolean, ms = 3000): Promise<void> {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > ms) throw new Error('waitFor 超时');
    await new Promise((r) => setTimeout(r, 5));
  }
}

test('cmd 往返: stage_begin 广播 → 命令双端可见 → 首个 ack 生效 → stage_end 带结果', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'p2' });
  const done = stages.startStage('w1', {
    code: `await stage.narrate('开演'); stage.end({ fin: true });`,
    actors: ACTORS,
  });
  assert.ok(done, '无进行中演出时应可开演');
  await waitFor(() => a.ofType('stage_cmd').length === 1);
  // 广播：两端都看到 begin + cmd
  assert.equal(a.ofType('stage_begin').length, 1);
  assert.equal(b.ofType('stage_begin').length, 1);
  const cmd = a.ofType('stage_cmd')[0];
  assert.equal(cmd.op, 'narrate');
  assert.deepEqual(cmd.args, { text: '开演' });
  assert.equal(b.ofType('stage_cmd').length, 1);
  // 双端都 ack：首个生效，次个安静忽略
  await a.say({ type: 'stage_event', kind: 'ack', cmdId: cmd.cmdId });
  await b.say({ type: 'stage_event', kind: 'ack', cmdId: cmd.cmdId });
  const r = await done;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { fin: true });
  assert.deepEqual(b.ofType('stage_end')[0]?.result, { fin: true });
  assert.equal(stages.activeIn('w1'), false);
});

test('客户端 abort: 演出被杀 → 广播 stage_abort → 世界可再次开演', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', { code: `await stage.sleep(600);`, actors: ACTORS });
  assert.ok(done);
  await waitFor(() => stages.activeIn('w1'));
  await a.say({ type: 'stage_event', kind: 'abort' });
  const r = await done!;
  assert.equal(r.status, 'killed');
  assert.match(String(a.ofType('stage_abort')[0]?.reason), /终止/);
  assert.equal(stages.activeIn('w1'), false);
  // 可再次开演
  const again = stages.startStage('w1', { code: `stage.end();`, actors: ACTORS });
  assert.ok(again);
  const r2 = await again!;
  assert.equal(r2.status, 'done');
});

test('ack 超时: 无人回执 → 脚本 error → 广播 stage_abort 带命令超时', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: `await stage.narrate('没人理我');`,
    actors: ACTORS,
    cmdTimeoutMs: 100,
  });
  const r = await done!;
  assert.equal(r.status, 'error');
  assert.match(String(a.ofType('stage_abort')[0]?.reason), /命令超时/);
});

test('同世界并发开演被拒: startStage 返回 null', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const first = stages.startStage('w1', { code: `await stage.sleep(600);`, actors: ACTORS });
  assert.ok(first);
  assert.equal(stages.startStage('w1', { code: `stage.end();`, actors: ACTORS }), null);
  stages.handleStageEvent('w1', { kind: 'abort' });
  await first!;
});

test('观众走光(leave_world): 世界清空即杀演出', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'p2' });
  const done = stages.startStage('w1', { code: `await stage.sleep(600);`, actors: ACTORS });
  await waitFor(() => stages.activeIn('w1'));
  await a.say({ type: 'leave_world' });
  assert.equal(stages.activeIn('w1'), true, '还剩一个观众，继续演');
  await b.say({ type: 'leave_world' });
  const r = await done!;
  assert.equal(r.status, 'killed');
  assert.equal(stages.activeIn('w1'), false);
});

test('开演时世界没人: 首条命令直接失败 → stage_abort', async () => {
  const { stages } = rig();
  const done = stages.startStage('w1', { code: `await stage.narrate('自言自语');`, actors: ACTORS });
  const r = await done!;
  assert.equal(r.status, 'error');
  assert.match(r.status === 'error' ? r.message : '', /没有观众/);
});

test('prop.create: 服务端造物管线出 spec → 广播 prop_spawn(不下发 prop_create) → 客户端落位 ack → 脚本拿到 id', async () => {
  let seenDesc = '';
  const maker: StagePropMaker = async (worldId, desc) => {
    seenDesc = `${worldId}:${desc}`;
    return { id: 'prop-1', spec: { kind: 'egg', size: 3 } };
  };
  const { stages, conn } = rig(maker);
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: `const egg = await stage.prop.create('一颗大蛋', 'a1'); stage.end({ pid: egg.id });`,
    actors: ACTORS,
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'prop_spawn'));
  // 客户端从不收到 prop_create（造不出 spec），只收 prop_spawn 携规格
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'prop_create'), false);
  const spawn = a.ofType('stage_cmd').find((m) => m.op === 'prop_spawn')!;
  assert.equal(seenDesc, 'w1:一颗大蛋');
  assert.deepEqual((spawn.args as Record<string, unknown>).spec, { kind: 'egg', size: 3 });
  assert.equal((spawn.args as Record<string, unknown>).near, 'a1');
  // 客户端落位后 ack 同 cmdId → 脚本 prop.create resolve
  await a.say({ type: 'stage_event', kind: 'ack', cmdId: spawn.cmdId, result: { id: 'prop-1' } });
  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { pid: 'prop-1' });
});

test('prop.create: 造物管线失败(返回 null) → 脚本 await 抛错 → stage_abort', async () => {
  const { stages, conn } = rig(async () => null);
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: `await stage.prop.create('坏东西', 'a1'); stage.end();`,
    actors: ACTORS,
  });
  const r = await done!;
  assert.equal(r.status, 'error');
  assert.match(String(a.ofType('stage_abort')[0]?.reason), /造物失败/);
});

test('规则订阅: on(tap) → 广播 watch(ev=tap) → 客户端 tap 事件注回脚本回调 → end', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: `stage.on('tap', stage.actors[0], () => stage.end({ tapped: true }));`,
    actors: ACTORS,
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'watch'));
  const watch = a.ofType('stage_cmd').find((m) => m.op === 'watch')!;
  assert.equal(watch.cmdId, -1, 'watch 无 ack 语义, cmdId=-1');
  assert.equal((watch.args as Record<string, unknown>).ev, 'tap');
  assert.equal(((watch.args as Record<string, unknown>).params as Record<string, unknown>).actorId, 'a1');
  const subId = (watch.args as Record<string, unknown>).subId as string;
  // 客户端探测到点击 → 上行 tap 事件 → 脚本回调触发 end
  await a.say({ type: 'stage_event', kind: 'tap', subId });
  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { tapped: true });
});

test('规则订阅: on(near) 不下发客户端 watch，服务端对复制位置边沿求值 → 触发 end', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    // 先发一条 hud 命令当「订阅已注册」门闩：host 按序处理 worker 消息，看到 hud_score 广播即证明其后 on(near) 的 subscribe 已登记。
    // actors[0]=a1(村民), actors[1]=p1(玩家)；靠近阈值 5（世界坐标）。
    code: `stage.hud.score('ready',''); stage.on('near', stage.actors[0], stage.actors[1], 5, () => stage.end({ caught: true }));`,
    actors: ACTORS,
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'hud_score'));
  // near 走服务端求值：客户端一条 watch 都不该收到（对比 tap/timer 会下发）。
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'watch'), false, 'near 不下发客户端探测器');
  // 远（dist=100）：不触发。
  stages.updatePositions('w1', [{ id: 'a1', x: 0, y: 0 }, { id: 'p1', x: 100, y: 0 }]);
  assert.equal(stages.activeIn('w1'), true, '还很远，不该触发');
  // 近（dist=2 ≤ 5）：远→近边沿触发回调 → end。
  stages.updatePositions('w1', [{ id: 'p1', x: 2, y: 0 }]);
  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { caught: true });
});

test('规则订阅: near 边沿——贴着不重复触发，离开后重新靠近再触发', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    // hud_score 当订阅门闩（见上一个 near 测试）；脚本内计数：第 2 次靠近才收场。
    code: `stage.hud.score('ready',''); let n = 0; stage.on('near', stage.actors[0], stage.actors[1], 5, () => { n++; if (n >= 2) stage.end({ n }); });`,
    actors: ACTORS,
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'hud_score'));
  stages.updatePositions('w1', [{ id: 'a1', x: 0, y: 0 }, { id: 'p1', x: 1, y: 0 }]); // 远→近：n=1
  stages.updatePositions('w1', [{ id: 'p1', x: 2, y: 0 }]);                          // 仍近：不计
  stages.updatePositions('w1', [{ id: 'p1', x: 100, y: 0 }]);                        // 近→远：复位
  stages.updatePositions('w1', [{ id: 'p1', x: 1, y: 0 }]);                          // 远→近：n=2 → end
  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { n: 2 }, '贴着那帧没多计，离开再来才第二次');
});

test('规则订阅: countdown.onDone → 广播 watch(ev=timer) → timer 事件归零触发 → end', async () => {
  const { stages, conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  const done = stages.startStage('w1', {
    code: `const t = stage.hud.countdown(60); t.onDone(() => stage.end({ timeUp: true }));`,
    actors: ACTORS,
    cmdTimeoutMs: 200,
  });
  await waitFor(() => a.ofType('stage_cmd').some((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer'));
  // 倒计时 HUD 命令也广播了(客户端渲染)
  assert.equal(a.ofType('stage_cmd').some((m) => m.op === 'hud_countdown'), true);
  const watch = a.ofType('stage_cmd').find((m) => m.op === 'watch' && (m.args as Record<string, unknown>).ev === 'timer')!;
  const subId = (watch.args as Record<string, unknown>).subId as string;
  await a.say({ type: 'stage_event', kind: 'timer', subId });
  const r = await done!;
  assert.equal(r.status, 'done');
  assert.deepEqual(a.ofType('stage_end')[0]?.result, { timeUp: true });
});
