import { test } from 'node:test';
import assert from 'node:assert/strict';
import { aggregateLevels, normalizeGpu, sanitizeLevels, sanitizeSample } from '../src/device_profile.ts';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';

test('aggregate: 逐旋钮取最保守——同 GPU 只要一台需要关，所有同型号都关', () => {
  const agg = aggregateLevels([
    { actor_shadows: 1, hi_res: 2, fog: 1 }, // 散热好的那台
    { actor_shadows: 0, hi_res: 2, fog: 1 }, // 这台必须关角色阴影才跑得动
    { actor_shadows: 1, hi_res: 1, fog: 1 }, // 这台清晰度得降一档
  ]);
  assert.deepEqual(agg, { actor_shadows: 0, hi_res: 1, fog: 1 });
});

test('aggregate: 单台样本原样下发；空样本返回 null（未命中）', () => {
  assert.deepEqual(aggregateLevels([{ fog: 1, hi_res: 0 }]), { fog: 1, hi_res: 0 });
  assert.equal(aggregateLevels([]), null);
});

test('aggregate: 客户端新增旋钮时，老样本没有的键不会凭空冒出来', () => {
  // 新版客户端多了 xray；老样本没这个键 → 聚合结果里 xray 取新样本的值，不影响其他键
  const agg = aggregateLevels([{ fog: 1 }, { fog: 0, xray: 1 }]);
  assert.deepEqual(agg, { fog: 0, xray: 1 });
});

test('sanitizeLevels: 合法档位表原样收下', () => {
  assert.deepEqual(sanitizeLevels({ hi_res: 2, fog: 0 }), { hi_res: 2, fog: 0 });
});

test('sanitizeLevels: 脏数据整份拒收，不让它污染众包', () => {
  assert.equal(sanitizeLevels(null), null);
  assert.equal(sanitizeLevels([]), null, '数组不是档位表');
  assert.equal(sanitizeLevels({}), null, '空表无意义');
  assert.equal(sanitizeLevels({ fog: 1.5 }), null, '级别必须是整数');
  assert.equal(sanitizeLevels({ fog: -1 }), null, '负级别');
  assert.equal(sanitizeLevels({ fog: 99 }), null, '越界级别');
  assert.equal(sanitizeLevels({ fog: '1' }), null, '字符串不是级别');
  assert.equal(sanitizeLevels({ 'DROP TABLE': 1 }), null, '非法键名');
  const tooMany: Record<string, number> = {};
  for (let i = 0; i < 40; i++) tooMany[`k${i}`] = 1;
  assert.equal(sanitizeLevels(tooMany), null, '键太多');
});

test('normalizeGpu: 厂商噪声后缀归一，同一颗 GPU 落同一个桶', () => {
  assert.equal(normalizeGpu('Adreno (TM) 610'), 'Adreno 610');
  assert.equal(normalizeGpu('Adreno(TM)  610'), 'Adreno 610');
  assert.equal(normalizeGpu('  Mali-G57 MC2 '), 'Mali-G57 MC2');
  assert.equal(normalizeGpu(''), null);
  assert.equal(normalizeGpu(123), null);
});

test('sanitizeSample: 完整样本收下，hit 缺省为 false', () => {
  const s = sanitizeSample({
    gpu: 'Mali-G57 MC2',
    benchVersion: 1,
    deviceId: 'dev-1',
    levels: { fog: 1, hi_res: 0 },
    p95Ms: 41.2,
  });
  assert.deepEqual(s, {
    gpu: 'Mali-G57 MC2',
    benchVersion: 1,
    deviceId: 'dev-1',
    levels: { fog: 1, hi_res: 0 },
    p95Ms: 41.2,
    hit: false,
  });
});

test('sanitizeSample: 缺字段/非法值一律拒收', () => {
  const base = { gpu: 'Mali-G57', benchVersion: 1, deviceId: 'd1', levels: { fog: 1 }, p95Ms: 30 };
  assert.ok(sanitizeSample(base));
  assert.equal(sanitizeSample({ ...base, gpu: '' }), null);
  assert.equal(sanitizeSample({ ...base, deviceId: '' }), null, '没有 deviceId 就无法防重复灌票');
  assert.equal(sanitizeSample({ ...base, p95Ms: 0 }), null);
  assert.equal(sanitizeSample({ ...base, p95Ms: -5 }), null);
  assert.equal(sanitizeSample({ ...base, p95Ms: 99_999 }), null);
  assert.equal(sanitizeSample({ ...base, benchVersion: 0 }), null);
  assert.equal(sanitizeSample({ ...base, levels: {} }), null);
});

// —— 路由往返：上传 → 下发 ——
test('/device-profile: 未命中的新 GPU → found=false（这台机器得当小白鼠跑 benchmark）', async (t) => {
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore() });
  t.after(() => app.close());
  const res = await app.inject({ method: 'GET', url: '/device-profile?gpu=Adreno%20999' });
  assert.equal(res.statusCode, 200);
  const body = res.json();
  assert.equal(body.found, false);
  assert.equal(body.samples, 0);
});

test('/device-profile: 两台同 GPU 上传 → 下发逐旋钮取最保守', async (t) => {
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore() });
  t.after(() => app.close());

  const post = (deviceId: string, levels: Record<string, number>, p95Ms: number) =>
    app.inject({
      method: 'POST',
      url: '/device-profile',
      payload: { gpu: 'Mali-G57 MC2', benchVersion: 1, deviceId, levels, p95Ms, hit: true },
    });

  assert.equal((await post('dev-a', { actor_shadows: 1, hi_res: 2 }, 28)).statusCode, 200);
  const second = await post('dev-b', { actor_shadows: 0, hi_res: 2 }, 31);
  assert.equal(second.json().samples, 2, '两台设备两票');

  // GPU 名带厂商噪声也要命中同一个桶
  const got = await app.inject({ method: 'GET', url: '/device-profile?gpu=Mali-G57%20MC2' });
  const body = got.json();
  assert.equal(body.found, true);
  assert.equal(body.samples, 2);
  assert.deepEqual(body.levels, { actor_shadows: 0, hi_res: 2 }, '一台要关角色阴影 → 同型号都关');
});

test('/device-profile: 同一台设备重测覆盖自己那票，不重复灌票', async (t) => {
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore() });
  t.after(() => app.close());
  const post = (levels: Record<string, number>) =>
    app.inject({
      method: 'POST',
      url: '/device-profile',
      payload: { gpu: 'Adreno 610', benchVersion: 1, deviceId: 'same-device', levels, p95Ms: 30, hit: true },
    });
  await post({ fog: 0 });
  const again = await post({ fog: 1 });
  assert.equal(again.json().samples, 1, '同一 deviceId 只占一行');
  assert.deepEqual(again.json().levels, { fog: 1 }, '新结果覆盖旧结果');
});

test('/device-profile: benchVersion 隔离——口径变了旧样本不会串过来', async (t) => {
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore() });
  t.after(() => app.close());
  await app.inject({
    method: 'POST',
    url: '/device-profile',
    payload: { gpu: 'Adreno 610', benchVersion: 1, deviceId: 'd1', levels: { fog: 0 }, p95Ms: 40, hit: false },
  });
  const v2 = await app.inject({ method: 'GET', url: '/device-profile?gpu=Adreno%20610&benchVersion=2' });
  assert.equal(v2.json().found, false, 'v2 口径下看不到 v1 的样本');
  const v1 = await app.inject({ method: 'GET', url: '/device-profile?gpu=Adreno%20610&benchVersion=1' });
  assert.equal(v1.json().found, true);
});

test('/device-profile: 脏上传回 400', async (t) => {
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore() });
  t.after(() => app.close());
  const bad = await app.inject({
    method: 'POST',
    url: '/device-profile',
    payload: { gpu: 'X', benchVersion: 1, deviceId: 'd', levels: { fog: 99 }, p95Ms: 30 },
  });
  assert.equal(bad.statusCode, 400);
  const noGpu = await app.inject({ method: 'GET', url: '/device-profile' });
  assert.equal(noGpu.statusCode, 400);
});
