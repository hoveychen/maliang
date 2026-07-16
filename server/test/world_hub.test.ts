import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldHub, type HubMember } from '../src/world_hub.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { DEFAULT_SCENE } from '../src/types.ts';

function member(clientId: string, inbox: Record<string, unknown>[], sceneId = DEFAULT_SCENE): HubMember {
  // 广播走 sendText(预序列化的字符串)；helper 解析回对象让断言照旧比对内容。
  return {
    clientId, playerId: `p-${clientId}`, sceneId,
    send: (m) => inbox.push(m),
    sendText: (s) => inbox.push(JSON.parse(s)),
    posBin: false, sendBin: () => {},
  };
}

test('双连接同世界互见: 首位是 host, 广播可排除发送者', () => {
  const hub = new WorldHub();
  const inboxA: Record<string, unknown>[] = [];
  const inboxB: Record<string, unknown>[] = [];
  const a = hub.join('w1', member('cA', inboxA));
  const b = hub.join('w1', member('cB', inboxB));
  assert.equal(a.isHost, true);
  assert.equal(b.isHost, false);
  assert.deepEqual(hub.membersIn('w1').map((m) => m.clientId), ['cA', 'cB']);
  assert.equal(hub.hostOf('w1')?.clientId, 'cA');
  const n = hub.broadcast('w1', { type: 'hello' }, 'cA');
  assert.equal(n, 1);
  assert.equal(inboxA.length, 0);
  assert.deepEqual(inboxB, [{ type: 'hello' }]);
});

test('host 断开 ⇒ 次位晋升并被返回; 最后一人离开 ⇒ 世界清空', () => {
  const hub = new WorldHub();
  const inbox: Record<string, unknown>[] = [];
  hub.join('w1', member('cA', inbox));
  hub.join('w1', member('cB', inbox));
  const left = hub.leave('cA');
  assert.equal(left?.worldId, 'w1');
  assert.equal(left?.newHost?.clientId, 'cB');
  assert.equal(hub.hostOf('w1')?.clientId, 'cB');
  // 非 host 离开不触发换任
  hub.join('w1', member('cC', inbox));
  const left2 = hub.leave('cC');
  assert.equal(left2?.newHost, null);
  // 最后一人
  const left3 = hub.leave('cB');
  assert.equal(left3?.newHost, null);
  assert.deepEqual(hub.membersIn('w1'), []);
  assert.equal(hub.hostOf('w1'), null);
  // 不在任何世界的连接 leave 无害
  assert.equal(hub.leave('cB'), null);
});

test('换世界: join 新世界自动从旧世界摘出, 旧世界 host 变更随 departed 返回', () => {
  const hub = new WorldHub();
  const inbox: Record<string, unknown>[] = [];
  hub.join('w1', member('cA', inbox));
  hub.join('w1', member('cB', inbox));
  const moved = hub.join('w2', member('cA', inbox));
  assert.equal(moved.isHost, true, '新世界首位即 host');
  assert.equal(moved.departed?.worldId, 'w1');
  assert.equal(moved.departed?.newHost?.clientId, 'cB');
  assert.equal(hub.worldOf('cA'), 'w2');
  assert.deepEqual(hub.membersIn('w1').map((m) => m.clientId), ['cB']);
});

test('重复 join 同世界: 保序不换 host, 只更新成员信息', () => {
  const hub = new WorldHub();
  const inbox: Record<string, unknown>[] = [];
  hub.join('w1', member('cA', inbox));
  hub.join('w1', member('cB', inbox));
  const again = hub.join('w1', member('cA', inbox));
  assert.equal(again.isHost, true);
  assert.deepEqual(hub.membersIn('w1').map((m) => m.clientId), ['cA', 'cB']);
});

test('死连接不拖累广播: send 抛错跳过继续发', () => {
  const hub = new WorldHub();
  const inbox: Record<string, unknown>[] = [];
  hub.join('w1', {
    clientId: 'dead', playerId: 'p', sceneId: DEFAULT_SCENE,
    send: () => { throw new Error('closed'); },
    sendText: () => { throw new Error('closed'); },
    posBin: false, sendBin: () => { throw new Error('closed'); },
  });
  hub.join('w1', member('cB', inbox));
  const n = hub.broadcast('w1', { type: 'ping' });
  assert.equal(n, 1);
  assert.deepEqual(inbox, [{ type: 'ping' }]);
});

test('序列化一次: 广播只 stringify 一次, 同一份字符串发给全场', () => {
  const hub = new WorldHub();
  const raw: string[] = [];
  const spy = (clientId: string): HubMember => ({
    clientId, playerId: `p-${clientId}`, sceneId: DEFAULT_SCENE,
    send: () => {}, sendText: (s) => raw.push(s),
    posBin: false, sendBin: () => {},
  });
  hub.join('w1', spy('cA'));
  hub.join('w1', spy('cB'));
  hub.join('w1', spy('cC'));
  const n = hub.broadcast('w1', { type: 'positions_relay', t: 1, chars: [{ id: 'x', x: 1, y: 2 }] });
  assert.equal(n, 3);
  assert.equal(raw.length, 3, '三个成员各收一次');
  assert.equal(raw[0], raw[1], '内容一致');
  assert.ok(raw[0] === raw[1] && raw[1] === raw[2], '是同一份字符串引用(证明只序列化一次)');
});

// ---- handleWsMessage 接线 ----

function wsRig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const conn = (connKey: string) => {
    const sent: { type: string; [k: string]: unknown }[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: Record<string, unknown>) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub);
    return { sent, say };
  };
  return { hub, conn };
}

test('world_info 经 hub 登记: 首连 world_host isHost=true, 次连 false', async () => {
  const { hub, conn } = wsRig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'p2' });
  const hostMsgA = a.sent.find((m) => m.type === 'world_host');
  const hostMsgB = b.sent.find((m) => m.type === 'world_host');
  assert.deepEqual(hostMsgA, { type: 'world_host', isHost: true });
  assert.deepEqual(hostMsgB, { type: 'world_host', isHost: false });
  assert.equal(hub.membersIn('w1').length, 2);
});

test('leave_world 摘出 hub 并推新 host 通知', async () => {
  const { hub, conn } = wsRig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'p1' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'p2' });
  await a.say({ type: 'leave_world' });
  assert.equal(hub.membersIn('w1').length, 1);
  const promoted = b.sent.filter((m) => m.type === 'world_host');
  assert.deepEqual(promoted.at(-1), { type: 'world_host', isHost: true }, '晋升通知推给了次位');
});

test('time_sync: 回带 t0 + 服务端毫秒钟', async () => {
  const { conn } = wsRig();
  const a = conn('cA');
  const before = Date.now();
  await a.say({ type: 'time_sync', t0: 123456 });
  const reply = a.sent.find((m) => m.type === 'time_sync');
  assert.ok(reply);
  assert.equal(reply.t0, 123456);
  assert.equal(typeof reply.serverMs, 'number');
  assert.ok((reply.serverMs as number) >= before);
});
