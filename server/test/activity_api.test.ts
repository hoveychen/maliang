/**
 * GET /debug/api/activity —— 管理台的 activity 记录数据源。
 * 会话 + 设备快照，倒序分页，派生玩家昵称与时长。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { FastifyInstance } from 'fastify';

describe('GET /debug/api/activity', () => {
  let app: FastifyInstance;
  let store: WorldStore;

  before(async () => {
    store = new WorldStore();
    store.createWorld('w1');
    store.upsertPlayer({ id: 'p1', name: '乐高', nickname: '小乐高', gender: 'boy', color: '红', spriteAsset: '', createdAt: '2026-07-10' });
    // 一条带完整设备快照、已结束的会话
    const id1 = store.startVisit('w1', 'p1', 1000, { ip: '1.2.3.4', ua: 'UA', model: 'MatePad', os: 'Android', osVersion: '14' });
    store.endVisit(id1, 4000);
    // 一条进行中、无设备（旧路径）
    store.startVisit('w1', 'p1', 5000);
    app = await buildServer({ adapters: createMockAdapters(), store });
  });
  after(async () => {
    await app.close();
  });

  it('返回会话 + 设备快照，倒序，带派生昵称与时长', async () => {
    const res = await app.inject({ method: 'GET', url: '/debug/api/activity' });
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.payload) as {
      total: number;
      activity: { playerName: string; startedAt: number; endedAt: number | null; durationMs: number | null; device: unknown }[];
    };
    assert.equal(body.total, 2);
    assert.equal(body.activity.length, 2);
    // 倒序：最新（startedAt 5000，进行中）在最前
    assert.equal(body.activity[0]!.startedAt, 5000);
    assert.equal(body.activity[0]!.endedAt, null);
    assert.equal(body.activity[0]!.durationMs, null, '进行中的没有时长');
    assert.equal(body.activity[0]!.device, null, '旧路径无设备');
    // 第二条：带设备 + 派生昵称 + 时长
    const done = body.activity[1]!;
    assert.equal(done.playerName, '小乐高', '派生玩家昵称');
    assert.equal(done.durationMs, 3000, '4000-1000');
    assert.deepEqual(done.device, { ip: '1.2.3.4', ua: 'UA', model: 'MatePad', os: 'Android', osVersion: '14' });
  });

  it('分页：limit/offset 生效，total 反映全量', async () => {
    const res = await app.inject({ method: 'GET', url: '/debug/api/activity?limit=1&offset=0' });
    const body = JSON.parse(res.payload) as { total: number; limit: number; activity: unknown[] };
    assert.equal(body.total, 2, 'total 是全量，不受分页影响');
    assert.equal(body.limit, 1);
    assert.equal(body.activity.length, 1);
  });

  it('带 token 门禁：配了 token 时无 token 请求被挡', async () => {
    process.env.MALIANG_ADMIN_TOKEN = 'secret';
    const guarded = await buildServer({ adapters: createMockAdapters(), store });
    try {
      const denied = await guarded.inject({ method: 'GET', url: '/debug/api/activity' });
      assert.equal(denied.statusCode, 403);
      const ok = await guarded.inject({ method: 'GET', url: '/debug/api/activity', headers: { 'x-admin-token': 'secret' } });
      assert.equal(ok.statusCode, 200);
    } finally {
      await guarded.close();
      delete process.env.MALIANG_ADMIN_TOKEN;
    }
  });
});
