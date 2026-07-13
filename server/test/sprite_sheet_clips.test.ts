import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PNG } from 'pngjs';
import {
  packAtlas,
  videoToSpriteSheet,
  videosToSpriteSheet,
  type ClipName,
} from '../src/sprite_sheet.ts';
import type { ImageBlob, VideoBlob } from '../src/adapters/types.ts';

const execFileP = promisify(execFile);

/**
 * 合成一段 16:9 绿幕视频，中间一个红「角色」块（尺寸可调，模拟不同段里角色占幅不同：
 * idle 站直较窄、moving 迈步较宽、talking 挥手更宽）。1s @ 25fps。
 */
async function greenClip(boxW: number, boxH: number): Promise<VideoBlob> {
  const dir = await mkdtemp(join(tmpdir(), 'mlclip-'));
  try {
    const out = join(dir, 'c.mp4');
    const x = Math.round((320 - boxW) / 2);
    const y = Math.round((180 - boxH) / 2);
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=0x00B140:s=320x180:d=1:r=25',
      '-vf', `drawbox=x=${x}:y=${y}:w=${boxW}:h=${boxH}:color=0xDC2828:t=fill`,
      '-pix_fmt', 'yuv420p', out,
    ]);
    return { bytes: new Uint8Array(await readFile(out)), mime: 'video/mp4' };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

/** 造一张纯色不透明 PNG（packAtlas 的纯函数测试用，不碰 ffmpeg）。 */
function solidFrame(w: number, h: number): ImageBlob {
  const png = new PNG({ width: w, height: h });
  for (let i = 0; i < w * h; i++) png.data[i * 4 + 3] = 255;
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

test('videosToSpriteSheet: 三段打进一张图集，clips 区间连续且覆盖全部帧', async () => {
  const clips: { name: ClipName; mp4: VideoBlob }[] = [
    { name: 'idle', mp4: await greenClip(60, 150) },
    { name: 'moving', mp4: await greenClip(90, 150) },
    { name: 'talking', mp4: await greenClip(75, 150) },
  ];
  const { meta } = await videosToSpriteSheet(clips, { webp: false, fps: 8 });

  assert.ok(meta.clips, 'meta 必须带 clips');
  const c = meta.clips!;
  for (const name of ['idle', 'moving', 'talking'] as const) {
    assert.ok(c[name], `缺段 ${name}`);
    assert.ok(c[name]!.count > 0, `${name} 帧数应 >0`);
  }
  // 段首尾相接、无空洞、无重叠，且合起来正好是 frameCount
  assert.equal(c.idle!.start, 0, 'idle 应从 0 开始');
  assert.equal(c.moving!.start, c.idle!.start + c.idle!.count, 'moving 应紧接 idle');
  assert.equal(c.talking!.start, c.moving!.start + c.moving!.count, 'talking 应紧接 moving');
  assert.equal(
    c.talking!.start + c.talking!.count,
    meta.frameCount,
    '三段应正好铺满 frameCount',
  );
  // 网格容得下所有帧
  assert.ok(meta.cols * meta.rows >= meta.frameCount, '网格应容得下所有帧');
  assert.equal(meta.width, meta.cols * meta.cellW);
  assert.equal(meta.height, meta.rows * meta.cellH);
});

test('videosToSpriteSheet: 三段共用同一并集裁剪盒（分开裁会各得各的 cell 尺寸 → 切段身高跳）', async () => {
  // 角色在三段里占幅不同：idle 最窄、moving 最宽。若各段独立裁剪，cellW 会各不相同。
  const idleMp4 = await greenClip(60, 120);
  const movingMp4 = await greenClip(110, 150);

  // 对照组：各段单独走老的单段管线 —— 证明「分开裁确实会得到不同 cell 尺寸」，
  // 否则本测试就是在断言一个恒真命题（那样它抓不到任何回归）。
  const soloIdle = await videoToSpriteSheet(idleMp4, { webp: false, fps: 8 });
  const soloMoving = await videoToSpriteSheet(movingMp4, { webp: false, fps: 8 });
  assert.notEqual(
    soloIdle.meta.cellW,
    soloMoving.meta.cellW,
    '前提不成立：两段单独裁本应得到不同 cellW，测试素材需要更大差异',
  );
  assert.notEqual(soloIdle.meta.cellH, soloMoving.meta.cellH, '前提不成立：两段单独裁本应得到不同 cellH');

  // 实验组：合并成一张三段图集 —— 只有一组 cellW/cellH，且盒子必须罩得住最大的那段。
  const { meta } = await videosToSpriteSheet(
    [
      { name: 'idle', mp4: idleMp4 },
      { name: 'moving', mp4: movingMp4 },
    ],
    { webp: false, fps: 8 },
  );
  assert.ok(
    meta.cellW >= soloMoving.meta.cellW,
    `共用盒应罩得住最宽的段：cellW ${meta.cellW} 应 >= ${soloMoving.meta.cellW}`,
  );
  assert.ok(
    meta.cellH >= soloMoving.meta.cellH,
    `共用盒应罩得住最高的段：cellH ${meta.cellH} 应 >= ${soloMoving.meta.cellH}`,
  );
  // 客户端按 cellH 归一化世界高度，全段只有这一个值 → 切段不会跳。
  // （packAtlas 本身也会对尺寸不一的帧抛错，这里再从 meta 侧钉一遍语义。）
});

test('videoToSpriteSheet: 老的单段管线不写 clips（v1 图集保持原样，客户端按 idle-only 处理）', async () => {
  const { meta } = await videoToSpriteSheet(await greenClip(80, 150), { webp: false, fps: 8 });
  assert.equal(meta.clips, undefined, '单段管线不应写 clips 字段');
  assert.ok(meta.frameCount > 0);
});

test('packAtlas: clips 区间越界要抛错（防止下发让 shader 采到空格子的 meta）', () => {
  const frames = [solidFrame(10, 20), solidFrame(10, 20), solidFrame(10, 20)];
  assert.doesNotThrow(() => packAtlas(frames, 8, { idle: { start: 0, count: 3 } }));
  assert.throws(
    () => packAtlas(frames, 8, { idle: { start: 0, count: 2 }, moving: { start: 2, count: 2 } }),
    /越界/,
    'moving 区间 [2,4) 超出 3 帧，应抛错',
  );
  assert.throws(
    () => packAtlas(frames, 8, { idle: { start: -1, count: 2 } }),
    /越界/,
    '负起点应抛错',
  );
  assert.throws(
    () => packAtlas(frames, 8, { idle: { start: 0, count: 0 } }),
    /越界/,
    '空段应抛错',
  );
});
