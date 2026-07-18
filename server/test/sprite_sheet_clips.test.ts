import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { PNG } from 'pngjs';
import {
  CLIP_NAMES,
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

/** 绿幕上合成带 2px 软边的白圆，再压成 yuv420p；复现真实视频轮廓的绿幕混色。 */
async function softEdgeClip(): Promise<VideoBlob> {
  const dir = await mkdtemp(join(tmpdir(), 'mlsoftedge-'));
  try {
    const w = 320;
    const h = 180;
    const src = new PNG({ width: w, height: h });
    const cx = w / 2;
    const cy = h / 2;
    const radius = 58;
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const dist = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
        const a = Math.max(0, Math.min(1, (radius + 1 - dist) / 2));
        const i = (y * w + x) * 4;
        src.data[i] = Math.round(255 * a);
        src.data[i + 1] = Math.round(255 * a + 177 * (1 - a));
        src.data[i + 2] = Math.round(255 * a + 64 * (1 - a));
        src.data[i + 3] = 255;
      }
    }
    const input = join(dir, 'edge.png');
    const output = join(dir, 'edge.mp4');
    await writeFile(input, PNG.sync.write(src));
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error', '-loop', '1', '-i', input,
      '-t', '1', '-r', '25', '-pix_fmt', 'yuv420p', output,
    ]);
    return { bytes: new Uint8Array(await readFile(output)), mime: 'video/mp4' };
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

test('videosToSpriteSheet: 多段打进一张图集，clips 区间连续且覆盖全部帧', async () => {
  // 用三段跑（含 moving）—— 打包器本身对段数/段名不设限，是 CLIP_NAMES 决定实际生成哪几段。
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
    '各段应正好铺满 frameCount',
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

test('cell 宽高必须是 4 的倍数（客户端 GPU 块压缩的地基：否则帧与帧会串色）', async () => {
  // 挑一批会裁出「非 4 倍数」内容盒的角色宽度，逐个验证输出仍对齐到 4。
  for (const boxW of [61, 62, 63, 65, 77]) {
    const { meta } = await videosToSpriteSheet(
      [
        { name: 'idle', mp4: await greenClip(boxW, 121) },
        { name: 'moving', mp4: await greenClip(boxW + 1, 122) },
      ],
      { webp: false, fps: 8 },
    );
    assert.equal(meta.cellW % 4, 0, `cellW ${meta.cellW} 应是 4 的倍数(源宽 ${boxW})`);
    assert.equal(meta.cellH % 4, 0, `cellH ${meta.cellH} 应是 4 的倍数(源宽 ${boxW})`);
    // 整张图集也随之对齐 —— 否则 Godot 会静默把图集 resize 到 4 的倍数，所有 UV 一起算错格。
    assert.equal(meta.width % 4, 0, '图集宽应是 4 的倍数');
    assert.equal(meta.height % 4, 0, '图集高应是 4 的倍数');
  }
});

test('videoToSpriteSheet: 老的单段管线不写 clips（v1 图集保持原样，客户端按 idle-only 处理）', async () => {
  const { meta } = await videoToSpriteSheet(await greenClip(80, 150), { webp: false, fps: 8 });
  assert.equal(meta.clips, undefined, '单段管线不应写 clips 字段');
  assert.ok(meta.frameCount > 0);
});

test('videoToSpriteSheet: 原分辨率软抠后再缩放，不产生不透明绿圈', async () => {
  const { atlas, meta } = await videoToSpriteSheet(await softEdgeClip(), {
    webp: false,
    fps: 1,
    cellH: 90,
    dropLastFrame: false,
  });
  const png = PNG.sync.read(Buffer.from(atlas.bytes));
  let softAlpha = 0;
  let opaqueGreenSpill = 0;
  for (let y = 0; y < meta.cellH; y++) {
    for (let x = 0; x < meta.cellW; x++) {
      const i = (y * png.width + x) * 4;
      const a = png.data[i + 3]!;
      if (a > 0 && a < 255) softAlpha++;
      if (a >= 240 && png.data[i + 1]! > Math.max(png.data[i]!, png.data[i + 2]!) + 5) {
        opaqueGreenSpill++;
      }
    }
  }
  assert.ok(softAlpha > 0, '视频轮廓应保留软 alpha，不能退化成 0/255 硬边');
  assert.equal(opaqueGreenSpill, 0, `不应残留不透明绿边，实际 ${opaqueGreenSpill} 像素`);
});

test('CLIP_NAMES 只含 idle 与 talking —— moving 不生成（走路是客户端程序化的）', () => {
  // 实测 Seedance 做不出这些角色的行走循环（腿被裙子挡住 → 改成原地转身摇摆、道具换手、
  // 横漂 0.87m）。这条断言钉住那个决定：真要重开 moving，改这里时会看到原因。
  assert.deepEqual([...CLIP_NAMES], ['idle', 'talking']);
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
