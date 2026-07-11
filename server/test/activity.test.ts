/**
 * activity 记录：会话级设备快照。
 *
 * 每次进世界（world_info）落一行 visits，带一份设备快照——服务端被动拿的 IP/UA +
 * 客户端上报的机型/系统。用来回答"谁、用什么设备、何时来、玩多久"。
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { buildDeviceSnapshot, clientIp, handleWsMessage, newVoiceSession } from '../src/server.ts';

describe('clientIp：反代下取真实客户端 IP', () => {
  it('有 x-forwarded-for → 取最左（最初的客户端）', () => {
    assert.equal(clientIp({ headers: { 'x-forwarded-for': '1.2.3.4, 10.0.0.1, 10.0.0.2' }, ip: '10.0.0.2' }), '1.2.3.4');
  });
  it('x-forwarded-for 是数组（多个头）→ 取第一个的最左', () => {
    assert.equal(clientIp({ headers: { 'x-forwarded-for': ['5.6.7.8, 10.0.0.1'] }, ip: '10.0.0.1' }), '5.6.7.8');
  });
  it('没有反代头（本地直连）→ 退回 req.ip', () => {
    assert.equal(clientIp({ headers: {}, ip: '127.0.0.1' }), '127.0.0.1');
  });
  it('都没有 → undefined，不瞎编', () => {
    assert.equal(clientIp({ headers: {} }), undefined);
  });
});

describe('buildDeviceSnapshot：连接层 + 客户端上报合并', () => {
  it('IP/UA 来自连接层，机型/系统来自客户端上报', () => {
    const snap = buildDeviceSnapshot(
      { connIp: '1.2.3.4', connUa: 'Mozilla/5.0 (Linux; Android 14)' },
      { model: 'HUAWEI MatePad', os: 'Android', osVersion: '14', screen: '2000x1200', godot: '4.6', app: 'abc123' },
    );
    assert.ok(snap);
    assert.equal(snap.ip, '1.2.3.4');
    assert.equal(snap.ua, 'Mozilla/5.0 (Linux; Android 14)');
    assert.equal(snap.model, 'HUAWEI MatePad');
    assert.equal(snap.os, 'Android');
    assert.equal(snap.screen, '2000x1200');
  });
  it('只有连接层（旧客户端不上报机型）→ 仍出快照，只是机型为空', () => {
    const snap = buildDeviceSnapshot({ connIp: '1.2.3.4' }, undefined);
    assert.ok(snap, '至少有 IP 就该出快照');
    assert.equal(snap.ip, '1.2.3.4');
    assert.equal(snap.model, undefined);
  });
  it('全空（本地直连、无上报）→ null，不落一行全空的快照', () => {
    assert.equal(buildDeviceSnapshot({}, undefined), null);
  });
  it('上报字段做长度夹紧（不可信输入）', () => {
    const snap = buildDeviceSnapshot({}, { model: 'x'.repeat(500) });
    assert.ok(snap);
    assert.equal(snap.model!.length, 128);
  });
  it('空串上报按缺省处理（不落空串）', () => {
    assert.equal(buildDeviceSnapshot({ connIp: '' }, { model: '  ' }), null);
  });
});

describe('startVisit/listActivity：设备快照落库与读回', () => {
  it('存进去能原样读回来', () => {
    const store = new WorldStore();
    const dev = { ip: '1.2.3.4', ua: 'UA', model: 'MatePad', os: 'Android', osVersion: '14', screen: '2000x1200', godot: '4.6', app: 'g' };
    store.startVisit('w1', 'p1', 1000, dev);
    const acts = store.listActivity();
    assert.equal(acts.length, 1);
    assert.deepEqual(acts[0]!.device, dev);
    assert.equal(acts[0]!.startedAt, 1000);
  });
  it('不带设备（旧路径）→ device 为 null，不炸', () => {
    const store = new WorldStore();
    store.startVisit('w1', 'p1', 1000);
    assert.equal(store.listActivity()[0]!.device, null);
  });
  it('倒序 + 分页', () => {
    const store = new WorldStore();
    for (let i = 0; i < 5; i++) store.startVisit('w1', `p${i}`, 1000 + i);
    const page = store.listActivity(2, 0);
    assert.equal(page.length, 2);
    assert.equal(page[0]!.startedAt, 1004, '最新的在最前');
    assert.equal(store.countVisits(), 5);
  });
});

describe('迁移：旧库 visits 无 device 列 → 补列，旧行读为 null', () => {
  it('手工建一个没有 device 列的旧库，WorldStore 打开后能加列且旧数据完好', () => {
    const dir = mkdtempSync(join(tmpdir(), 'maliang-mig-'));
    try {
      // 造一个"旧版" world.db：visits 表没有 device 列，塞一行历史会话
      const raw = new DatabaseSync(join(dir, 'world.db'));
      raw.exec(`CREATE TABLE visits (id INTEGER PRIMARY KEY AUTOINCREMENT, world_id TEXT NOT NULL, player_id TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER)`);
      raw.prepare('INSERT INTO visits (world_id, player_id, started_at, ended_at) VALUES (?,?,?,?)').run('w1', 'old-player', 500, 600);
      raw.close();

      const store = new WorldStore(dir);
      const cols = (new DatabaseSync(join(dir, 'world.db'), { readOnly: true }).prepare('PRAGMA table_info(visits)').all() as { name: string }[]).map((c) => c.name);
      assert.ok(cols.includes('device'), '迁移后应有 device 列');

      const acts = store.listActivity();
      assert.equal(acts.length, 1, '旧行还在');
      assert.equal(acts[0]!.playerId, 'old-player');
      assert.equal(acts[0]!.device, null, '旧行的 device 读为 null');

      // 迁移后还能正常写带设备的新会话
      store.startVisit('w1', 'new-player', 700, { ip: '9.9.9.9' });
      assert.equal(store.listActivity()[0]!.device?.ip, '9.9.9.9');
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe('world_info 端到端：进世界即落设备快照', () => {
  it('session 带连接层 IP/UA + profile.device → 落库的 Visit 带完整快照', async () => {
    const store = new WorldStore();
    store.createWorld('w1');
    const socket = { send: () => {} };
    const session = newVoiceSession();
    // /ws 握手时会设这两个；测试里直接预置（handleWsMessage 不接 req）
    session.connIp = '1.2.3.4';
    session.connUa = 'Mozilla/5.0 (Linux; Android 14; HUAWEI)';
    const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session] as const;

    await handleWsMessage(
      socket,
      JSON.stringify({
        type: 'world_info',
        worldId: 'w1',
        playerId: 'p1',
        profile: { nickname: '小乐高', device: { model: 'HUAWEI MatePad', os: 'Android', osVersion: '14', screen: '2000x1200', godot: '4.6' } },
      }),
      ...rest,
    );

    const acts = store.listActivity();
    assert.equal(acts.length, 1, '进世界应落一条 activity');
    const d = acts[0]!.device;
    assert.ok(d);
    assert.equal(d.ip, '1.2.3.4', '连接层 IP');
    assert.equal(d.model, 'HUAWEI MatePad', '客户端上报机型');
    assert.equal(d.os, 'Android');
    assert.equal(acts[0]!.playerId, 'p1');
  });

  it('旧客户端不带 device，但服务端仍记下 IP/UA', async () => {
    const store = new WorldStore();
    store.createWorld('w1');
    const session = newVoiceSession();
    session.connIp = '8.8.8.8';
    const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'conn2', session] as const;

    await handleWsMessage(
      { send: () => {} },
      JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'p1' }),
      ...rest,
    );

    const d = store.listActivity()[0]!.device;
    assert.ok(d, '哪怕客户端啥都没上报，也该有 IP 快照');
    assert.equal(d.ip, '8.8.8.8');
    assert.equal(d.model, undefined);
  });
});
