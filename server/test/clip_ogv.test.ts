import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { SpriteSheetMeta } from '../src/sprite_sheet.ts';
import type { ToClipOgv } from '../src/clip_video.ts';
import type { VideoBlob } from '../src/adapters/types.ts';

const META: SpriteSheetMeta = {
  cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60,
};

/** 建一个 ready 且带 idle/talking 原片的 store，返回立绘 hash + 两段原片 hash。 */
function seedReadyAnim(store: WorldStore): { sprite: string; idle: string; talking: string } {
  const idle = store.putAsset({ bytes: Uint8Array.from([1, 1, 1, 1]), mime: 'video/mp4' });
  const talking = store.putAsset({ bytes: Uint8Array.from([2, 2, 2, 2]), mime: 'video/mp4' });
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9]), mime: 'image/png' });
  store.setSpriteAnimReady(sprite, 'atlas-hash', META, { clipVideos: { idle, talking } });
  return { sprite, idle, talking };
}

test('GET /sprite-anim/:hash/clip/:name.ogv: 惰转一次→回 ogv→缓存命中不重转', async () => {
  const store = new WorldStore();
  const { sprite } = seedReadyAnim(store);
  let calls = 0;
  const fakeOgv: ToClipOgv = async (mp4: VideoBlob) => {
    calls += 1;
    // 拿源片字节做点确定性变换，好验证「转的是哪一段」
    return { bytes: Uint8Array.from([0xff, ...mp4.bytes]), mime: 'video/ogg' };
  };
  const app = await buildServer({ adapters: createMockAdapters(), store, toClipOgv: fakeOgv });
  try {
    const url = `/sprite-anim/${sprite}/clip/idle.ogv`;
    const r1 = await app.inject({ method: 'GET', url });
    assert.equal(r1.statusCode, 200);
    assert.equal(r1.headers['content-type'], 'video/ogg');
    assert.match(String(r1.headers['cache-control']), /immutable/);
    assert.ok(r1.headers['etag'], '应带 etag');
    assert.deepEqual(new Uint8Array(r1.rawPayload), Uint8Array.from([0xff, 1, 1, 1, 1]));
    assert.equal(calls, 1);

    // clipOgv 已记，资产已入库
    const rec = store.getSpriteAnim(sprite);
    assert.ok(rec?.clipOgv?.idle, 'clipOgv.idle 应被记下');
    assert.ok(store.getAsset(rec!.clipOgv!.idle!), 'ogv 资产应入库');

    // 二次请求 → 缓存命中，不再转码
    const r2 = await app.inject({ method: 'GET', url });
    assert.equal(r2.statusCode, 200);
    assert.deepEqual(new Uint8Array(r2.rawPayload), Uint8Array.from([0xff, 1, 1, 1, 1]));
    assert.equal(calls, 1, '缓存命中不应重转');

    // If-None-Match 命中 → 304
    const etag = String(r1.headers['etag']);
    const r304 = await app.inject({ method: 'GET', url, headers: { 'if-none-match': etag } });
    assert.equal(r304.statusCode, 304);
  } finally {
    await app.close();
  }
});

test('GET clip ogv: 不同段各转各的', async () => {
  const store = new WorldStore();
  const { sprite } = seedReadyAnim(store);
  const fakeOgv: ToClipOgv = async (mp4) => ({ bytes: Uint8Array.from([0xee, ...mp4.bytes]), mime: 'video/ogg' });
  const app = await buildServer({ adapters: createMockAdapters(), store, toClipOgv: fakeOgv });
  try {
    const idle = await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}/clip/idle.ogv` });
    const talking = await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}/clip/talking.ogv` });
    assert.deepEqual(new Uint8Array(idle.rawPayload), Uint8Array.from([0xee, 1, 1, 1, 1]));
    assert.deepEqual(new Uint8Array(talking.rawPayload), Uint8Array.from([0xee, 2, 2, 2, 2]));
    const rec = store.getSpriteAnim(sprite);
    assert.ok(rec?.clipOgv?.idle && rec?.clipOgv?.talking, '两段各自缓存');
    assert.notEqual(rec!.clipOgv!.idle, rec!.clipOgv!.talking);
  } finally {
    await app.close();
  }
});

test('GET clip ogv: 并发同段只转一次（in-flight 去重）', async () => {
  const store = new WorldStore();
  const { sprite } = seedReadyAnim(store);
  let calls = 0;
  const slowOgv: ToClipOgv = async (mp4) => {
    calls += 1;
    await new Promise((r) => setTimeout(r, 30)); // 拖慢，制造并发窗口
    return { bytes: Uint8Array.from([0xcc, ...mp4.bytes]), mime: 'video/ogg' };
  };
  const app = await buildServer({ adapters: createMockAdapters(), store, toClipOgv: slowOgv });
  try {
    const url = `/sprite-anim/${sprite}/clip/idle.ogv`;
    const [a, b, c] = await Promise.all([
      app.inject({ method: 'GET', url }),
      app.inject({ method: 'GET', url }),
      app.inject({ method: 'GET', url }),
    ]);
    assert.equal(a.statusCode, 200);
    assert.equal(b.statusCode, 200);
    assert.equal(c.statusCode, 200);
    assert.equal(calls, 1, '并发同段应只跑一次转码');
  } finally {
    await app.close();
  }
});

test('GET clip ogv: 各类 404（无记录/未 ready/未知段/非 .ogv/缺原片）', async () => {
  const store = new WorldStore();
  const fakeOgv: ToClipOgv = async () => ({ bytes: Uint8Array.from([0]), mime: 'video/ogg' });
  const app = await buildServer({ adapters: createMockAdapters(), store, toClipOgv: fakeOgv });
  try {
    // 无 sprite-anim 记录
    assert.equal((await app.inject({ method: 'GET', url: '/sprite-anim/nope/clip/idle.ogv' })).statusCode, 404);

    // 记录存在但 pending（未 ready）
    const pend = store.putAsset({ bytes: Uint8Array.from([5]), mime: 'image/png' });
    store.setSpriteAnimPending(pend);
    assert.equal((await app.inject({ method: 'GET', url: `/sprite-anim/${pend}/clip/idle.ogv` })).statusCode, 404);

    const { sprite } = seedReadyAnim(store);
    // 非 .ogv 后缀
    assert.equal((await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}/clip/idle.mp4` })).statusCode, 404);
    // 未知段名
    assert.equal((await app.inject({ method: 'GET', url: `/sprite-anim/${sprite}/clip/dancing.ogv` })).statusCode, 404);

    // ready 但该段无原片：另建一个只有 idle 的记录，请求 talking（moving 不在 CLIP_NAMES，用 talking）
    const partialIdle = store.putAsset({ bytes: Uint8Array.from([7]), mime: 'video/mp4' });
    const partialSprite = store.putAsset({ bytes: Uint8Array.from([8]), mime: 'image/png' });
    store.setSpriteAnimReady(partialSprite, 'atlas2', META, { clipVideos: { idle: partialIdle } });
    assert.equal((await app.inject({ method: 'GET', url: `/sprite-anim/${partialSprite}/clip/talking.ogv` })).statusCode, 404);
  } finally {
    await app.close();
  }
});
