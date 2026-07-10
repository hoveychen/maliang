import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ScriptRunner } from '../src/stage_runner.ts';
import type { StageBackend, StageCommand, StageSubscription } from '../src/stage_types.ts';

const ACTORS = [
  { id: 'a1', name: '小鸭', isPlayer: false },
  { id: 'a2', name: '小鹅', isPlayer: false },
  { id: 'p1', name: '宝宝', isPlayer: true },
];

/** 记录命令的 mock 舞台；autoAck=false 时命令悬挂，由测试手动 ack。 */
class MockBackend implements StageBackend {
  cmds: StageCommand[] = [];
  subs: StageSubscription[] = [];
  autoAck = true;
  pending: { cmd: StageCommand; resolve: (v?: Record<string, unknown>) => void }[] = [];

  execCommand(cmd: StageCommand): Promise<Record<string, unknown> | void> {
    this.cmds.push(cmd);
    if (this.autoAck) return Promise.resolve();
    return new Promise((resolve) => this.pending.push({ cmd, resolve }));
  }

  onSubscribe(sub: StageSubscription): void {
    this.subs.push(sub);
  }
}

async function waitFor(pred: () => boolean, ms = 3000): Promise<void> {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > ms) throw new Error('waitFor 超时');
    await new Promise((r) => setTimeout(r, 5));
  }
}

test('顺序脚本: TS 类型剥离 + 命令按序下发 + end 带结果', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({
    code: `
      const greeting: string = '大家好';
      await stage.narrate('从前有只小鸭');
      const [duck] = cast('小鸭');
      await duck.say(greeting, 'wave');
      await duck.moveTo('pond');
      stage.end({ ok: true });
    `,
    actors: ACTORS,
  });
  assert.equal(r.status, 'done');
  if (r.status === 'done') assert.deepEqual(r.result, { ok: true });
  assert.deepEqual(
    backend.cmds.map((c) => c.op),
    ['narrate', 'say', 'move_to'],
  );
  assert.equal(backend.cmds[1].actorId, 'a1');
  assert.deepEqual(backend.cmds[1].args, { text: '大家好', action: 'wave' });
});

test('剧场型脚本: 主函数返回且无订阅 ⇒ 不用显式 end 也自然收场', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({ code: `await stage.narrate('只有一句');`, actors: ACTORS });
  assert.equal(r.status, 'done');
});

test('Promise.all 并行: 两条 move_to 都发出后才各自等 ack', async () => {
  const backend = new MockBackend();
  backend.autoAck = false;
  const runner = new ScriptRunner(backend);
  const done = runner.run({
    code: `
      const [duck, goose] = cast('小鸭', '小鹅');
      await Promise.all([duck.moveTo('pond'), goose.moveTo('pond')]);
      stage.end({ both: true });
    `,
    actors: ACTORS,
  });
  // 两条命令在任何 ack 之前都已发出 = 真并行
  await waitFor(() => backend.pending.length === 2);
  assert.deepEqual(backend.pending.map((p) => p.cmd.actorId).sort(), ['a1', 'a2']);
  backend.pending[0].resolve();
  backend.pending[1].resolve();
  const r = await done;
  assert.equal(r.status, 'done');
  if (r.status === 'done') assert.deepEqual(r.result, { both: true });
});

test('事件订阅: 主函数返回后挂住等事件，注入 near 触发回调 end', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const done = runner.run({
    code: `
      const [seeker] = cast('小鸭');
      seeker.follow(stage.player);
      stage.on('near', seeker, stage.player, 2, () => {
        stage.end({ caught: true });
      });
    `,
    actors: ACTORS,
  });
  await waitFor(() => runner.subscriptions.size === 1);
  const sub = [...runner.subscriptions.values()][0];
  assert.equal(sub.ev, 'near');
  assert.deepEqual(sub.params, { a: 'a1', b: 'p1', dist: 2 });
  // 有活跃订阅时脚本不收场
  await new Promise((r) => setTimeout(r, 50));
  assert.equal(runner.running, true);
  assert.equal(backend.cmds.some((c) => c.op === 'follow'), true);
  runner.emitEvent(sub.subId);
  const r = await done;
  assert.equal(r.status, 'done');
  if (r.status === 'done') assert.deepEqual(r.result, { caught: true });
});

test('hud.countdown: onDone 是 timer 订阅，事件触发回调', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const done = runner.run({
    code: `
      const t = stage.hud.countdown(60);
      t.onDone(() => stage.end({ timeup: true }));
    `,
    actors: ACTORS,
  });
  await waitFor(() => runner.subscriptions.size === 1);
  const sub = [...runner.subscriptions.values()][0];
  assert.equal(sub.ev, 'timer');
  assert.equal(backend.cmds.some((c) => c.op === 'hud_countdown'), true);
  runner.emitEvent(sub.subId);
  const r = await done;
  assert.equal(r.status, 'done');
  if (r.status === 'done') assert.deepEqual(r.result, { timeup: true });
});

test('整场超时: 脚本睡死被强杀, status=timeout', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({ code: `await stage.sleep(600);`, actors: ACTORS, timeoutMs: 200 });
  assert.equal(r.status, 'timeout');
});

test('整场超时: 同步死循环也能被 terminate 掉', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({ code: `for (;;) {}`, actors: ACTORS, timeoutMs: 200 });
  assert.equal(r.status, 'timeout');
});

test('单命令 ack 超时: 后端悬挂 ⇒ 脚本 await 抛错 ⇒ status=error', async () => {
  const backend = new MockBackend();
  backend.autoAck = false; // 永不 ack
  const runner = new ScriptRunner(backend);
  const r = await runner.run({
    code: `await stage.narrate('等不到 ack');`,
    actors: ACTORS,
    cmdTimeoutMs: 100,
  });
  assert.equal(r.status, 'error');
  if (r.status === 'error') assert.match(r.message, /命令超时/);
});

test('命令预算: 超上限终止, status=error', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({
    code: `for (let i = 0; i < 10; i++) await stage.narrate('话痨' + i);`,
    actors: ACTORS,
    maxCommands: 3,
  });
  assert.equal(r.status, 'error');
  if (r.status === 'error') assert.match(r.message, /预算/);
});

test('语法错误: 不起 worker 直接报 error', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({ code: `const = ;`, actors: ACTORS });
  assert.equal(r.status, 'error');
  if (r.status === 'error') assert.match(r.message, /语法错误/);
  assert.equal(backend.cmds.length, 0);
});

test('脚本运行异常(找不到角色): status=error 带信息', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const r = await runner.run({ code: `cast('不存在的角色');`, actors: ACTORS });
  assert.equal(r.status, 'error');
  if (r.status === 'error') assert.match(r.message, /找不到角色/);
});

test('kill: 外部强杀, status=killed', async () => {
  const backend = new MockBackend();
  const runner = new ScriptRunner(backend);
  const done = runner.run({ code: `await stage.sleep(600);`, actors: ACTORS });
  await waitFor(() => runner.running);
  runner.kill();
  const r = await done;
  assert.equal(r.status, 'killed');
});
