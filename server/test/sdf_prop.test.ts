import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { validateSdfPropSpec, fallbackSdfPropSpec } from '../src/sdf_prop.ts';

// ---- 校验器：与客户端 sdf_spec.gd 同规则 ----

test('validateSdfPropSpec: 接受合法 spec 并归一化', () => {
  const res = validateSdfPropSpec({
    name: 'walking_hut',
    palette: ['#B1543F', '#f4ead4'],
    blend: 0.3,
    outline: 0.045,
    parts: [
      { shape: 'box', pos: [0, 1.3, 0], size: [1.7, 1.2, 1.5], color: 1 },
      { shape: 'cone', pos: [0, 2.35, 0], r1: 1.05, r2: 0.18, h: 0.55, color: 0 },
    ],
    locomotion: { type: 'walker', legs: 4, leg_r: 0.12, hip_h: 0.78, stance: [0.6, 0.5], speed: 0.7 },
    ropes: [{ pos: [0, 2.05, -0.85], segments: 4, r: 0.09, len: 0.26, color: 0 }],
  });
  assert.ok(res.ok);
  if (res.ok) {
    assert.equal(res.spec.palette[0], '#b1543f'); // 归一化小写
    assert.equal(res.spec.locomotion.legs, 4);
    assert.equal(res.spec.ropes[0].segments, 4);
  }
});

test('validateSdfPropSpec: 结构性错误拒收', () => {
  const bad = [
    { palette: ['#fff'], parts: [{ shape: 'torus', pos: [0, 0, 0], color: 0 }] }, // 未知形状
    { palette: ['red'], parts: [{ shape: 'sphere', pos: [0, 0, 0], color: 0 }] }, // 非 hex 颜色
    { palette: ['#fff'], parts: [] }, // parts 为空
    {
      palette: ['#fff'],
      parts: [{ shape: 'sphere', pos: [0, 0, 0], color: 0 }],
      locomotion: { type: 'walker', legs: 5 },
    }, // 5 条腿
    {
      palette: ['#fff'],
      parts: Array.from({ length: 12 }, (_, i) => ({ shape: 'sphere', pos: [i, 0, 0], color: 0 })),
      locomotion: { type: 'walker', legs: 6 },
      ropes: [{ pos: [0, 1, 0], segments: 8, r: 0.05, len: 0.2, color: 0 }],
    }, // 12+12+8=32 超预算
  ];
  for (const b of bad) {
    const res = validateSdfPropSpec(b);
    assert.equal(res.ok, false, JSON.stringify(b).slice(0, 60));
  }
});

test('validateSdfPropSpec: 数值越界 clamp 而非拒收', () => {
  const res = validateSdfPropSpec({
    palette: ['#abc'],
    parts: [{ shape: 'sphere', pos: [99, -99, 0], r: 50, color: 9 }],
    locomotion: { type: 'hopper', hop_h: 10, rate: 100 },
  });
  assert.ok(res.ok);
  if (res.ok) {
    assert.equal(res.spec.parts[0].pos[0], 5); // pos clamp 到 ±5
    assert.equal(res.spec.parts[0].r, 2.5); // 半径 clamp
    assert.equal(res.spec.parts[0].color, 0); // 调色板索引 clamp
    assert.equal(res.spec.locomotion.hop_h, 1.5);
  }
});

test('fallbackSdfPropSpec 自身必须过校验', () => {
  assert.ok(validateSdfPropSpec(fallbackSdfPropSpec('x')).ok);
});

// ---- mock 适配器 ----

test('mock designSdfProp: 关键词决定运动方式，产物过校验', async () => {
  const llm = createMockAdapters().llm;
  const fly = await llm.designSdfProp('会飞的小灯笼');
  assert.equal(fly.locomotion.type, 'flyer');
  const hop = await llm.designSdfProp('蹦蹦跳跳的邮筒');
  assert.equal(hop.locomotion.type, 'hopper');
  const walk = await llm.designSdfProp('会走路的房子');
  assert.equal(walk.locomotion.type, 'walker');
  for (const s of [fly, hop, walk]) assert.ok(validateSdfPropSpec(s).ok);
});

// ---- 路由 ----

test('POST /sdf-props: 描述 → 校验后的 spec；空描述 400；违禁词 400', async () => {
  const dir = join(tmpdir(), 'maliang-test-sdf-props');
  rmSync(dir, { recursive: true, force: true });
  const app = await buildServer({ adapters: createMockAdapters(), store: new WorldStore(dir) });
  try {
    const ok = await app.inject({
      method: 'POST',
      url: '/sdf-props',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ description: '会走路的小房子' }),
    });
    assert.equal(ok.statusCode, 200);
    const body = ok.json() as { spec: { name: string; parts: unknown[]; locomotion: { type: string } } };
    assert.ok(body.spec.parts.length > 0);
    assert.equal(body.spec.locomotion.type, 'walker');

    const empty = await app.inject({
      method: 'POST',
      url: '/sdf-props',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({}),
    });
    assert.equal(empty.statusCode, 400);

    const blocked = await app.inject({
      method: 'POST',
      url: '/sdf-props',
      headers: { 'content-type': 'application/json' },
      payload: JSON.stringify({ description: '一把恐怖的枪' }),
    });
    assert.equal(blocked.statusCode, 400);
  } finally {
    await app.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
