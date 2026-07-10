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
function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const stages = new StageDirector(hub);
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
