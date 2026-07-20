import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { generateCharacterAnimation, repackFromStoredClips } from '../src/idle_animation.ts';
import { pregenerateClipOgv } from '../src/clip_video.ts';
import type { ToClipOgv } from '../src/clip_video.ts';
import type { SpriteSheetMeta } from '../src/sprite_sheet.ts';
import type { ToSpriteSheet } from '../src/idle_animation.ts';
import type { ServiceAdapters, ClipName } from '../src/adapters/types.ts';

const META: SpriteSheetMeta = {
  cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60,
};
const fakeSheet: ToSpriteSheet = async () => ({ atlas: { bytes: Uint8Array.from([1, 2, 3, 4]), mime: 'image/png' }, meta: META });
// 每段生成一个 >512 字节的「视频」（超过预生成的尺寸门槛），末字节按段名区分避免塌成同 hash。
function bigVideoAdapters(): ServiceAdapters {
  const a = createMockAdapters();
  a.video = {
    generateClip: async (_s, clip: ClipName) => {
      const tag = { idle: 0x69, moving: 0x6d, talking: 0x74 }[clip];
      const bytes = new Uint8Array(1024); bytes[1023] = tag!;
      return { bytes, mime: 'video/mp4' };
    },
  };
  return a;
}
// 假 ogv 转换：不碰 ffmpeg，回确定性字节（含源片末字节以区分段）。
const fakeOgv: ToClipOgv = async (mp4) => ({ bytes: Uint8Array.from([0xaa, mp4.bytes[mp4.bytes.length - 1]!]), mime: 'video/ogg' });

test('pregenerateClipOgv: 转各段入库 + 尺寸门槛跳过占位小 blob', async () => {
  const store = new WorldStore();
  const clips = [
    { name: 'idle' as ClipName, mp4: { bytes: new Uint8Array(1024).fill(1), mime: 'video/mp4' } },
    { name: 'talking' as ClipName, mp4: { bytes: Uint8Array.from([9, 9, 9]), mime: 'video/mp4' } }, // 3 字节 → 跳过
  ];
  const ogv = await pregenerateClipOgv(store, clips, fakeOgv);
  assert.ok(ogv.idle, 'idle(1KB) 应转码入库');
  assert.equal(ogv.talking, undefined, 'talking(3 字节) 应被尺寸门槛跳过');
  assert.ok(store.getAsset(ogv.idle!), 'idle ogv 资产应入库');
});

test('generateCharacterAnimation: ready 记录带预生成的 clipOgv', async () => {
  const store = new WorldStore();
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
  await generateCharacterAnimation(bigVideoAdapters(), store, sprite, fakeSheet, fakeOgv);
  const rec = store.getSpriteAnim(sprite);
  assert.equal(rec?.status, 'ready');
  assert.ok(rec?.clipVideos?.idle && rec?.clipVideos?.talking, 'clipVideos 齐全');
  assert.ok(rec?.clipOgv?.idle && rec?.clipOgv?.talking, 'clipOgv 应被预生成');
  assert.ok(store.getAsset(rec!.clipOgv!.idle!), 'idle ogv 资产入库');
  assert.notEqual(rec!.clipOgv!.idle, rec!.clipOgv!.talking, '两段 ogv 各异');
});

test('repackFromStoredClips: 重打时刷新 clipOgv 预缓存', async () => {
  const store = new WorldStore();
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
  // 先 generate 建出带原片的 ready 记录
  await generateCharacterAnimation(bigVideoAdapters(), store, sprite, fakeSheet, fakeOgv);
  // 篡改 clipOgv 为过期占位，验证 repack 会重刷
  const before = store.getSpriteAnim(sprite)!.clipOgv!.idle;
  const ok = await repackFromStoredClips(store, sprite, fakeSheet, fakeOgv);
  assert.equal(ok, true);
  const rec = store.getSpriteAnim(sprite);
  assert.ok(rec?.clipOgv?.idle && rec?.clipOgv?.talking, 'repack 后 clipOgv 仍齐全');
  // 同源同转换 → 内容寻址 hash 不变（幂等）
  assert.equal(rec!.clipOgv!.idle, before, 'repack 幂等:同内容同 hash');
});

test('generateCharacterAnimation: 占位小视频(mock 默认)不预生成 ogv、不报错', async () => {
  const store = new WorldStore();
  const sprite = store.putAsset({ bytes: Uint8Array.from([9, 9, 9]), mime: 'image/png' });
  // 默认 mock 的 videoStub 是 9 字节 → 尺寸门槛跳过（且此处 toClipOgv 用默认真 ffmpeg 也不会被调到）
  await generateCharacterAnimation(createMockAdapters(), store, sprite, fakeSheet);
  const rec = store.getSpriteAnim(sprite);
  assert.equal(rec?.status, 'ready', '仍 ready，不因 ogv 预生成受影响');
  assert.deepEqual(rec?.clipOgv, {}, '占位视频 → clipOgv 为空（尺寸门槛跳过）');
});
