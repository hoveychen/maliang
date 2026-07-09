import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { videoToSpriteSheet } from '../src/sprite_sheet.ts';

const execFileP = promisify(execFile);

/**
 * 合成一段 16:9 绿幕视频：纯绿背景 + 竖向细长红色「角色」块占帧高 ~85%、帧宽 ~28%
 * （模拟真实 idle 视频取景：角色竖向贴满、横向大片绿边）。返回 mp4 字节。
 */
async function makeGreenIdleMp4(): Promise<Uint8Array> {
  const dir = await mkdtemp(join(tmpdir(), 'mltest-'));
  try {
    const out = join(dir, 'idle.mp4');
    // 320x180 绿底；红块 x[116..204)（28%宽居中）y[13..167)（~85%高居中），1s @ 25fps。
    await execFileP('ffmpeg', [
      '-y', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=0x00B140:s=320x180:d=1:r=25',
      '-vf', 'drawbox=x=116:y=13:w=88:h=154:color=0xDC2828:t=fill',
      '-pix_fmt', 'yuv420p', out,
    ]);
    return new Uint8Array(await readFile(out));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

test('videoToSpriteSheet 默认分辨率：角色 cell 高度显著高于旧 160 档', async () => {
  const mp4 = await makeGreenIdleMp4();
  // webp:false 直接拿 PNG 图集，免依赖 cwebp 输出的元信息
  const { meta } = await videoToSpriteSheet({ bytes: mp4, mime: 'video/mp4' }, { webp: false });

  // 默认 cellH=256，角色占帧高 ~85% → 裁后 cell 高 ≈ 0.85*256 ≈ 218（+pad）。
  // 旧默认 160 只会得到 ~136 —— 断言 > 180 即证明分辨率档已抬升，不会退回旧值。
  assert.ok(
    meta.cellH > 180,
    `角色 cell 高应 >180(证明分辨率提升)，实得 ${meta.cellH}`,
  );
  // 横向绿边被 unionCrop 裁掉：cell 宽应远小于整帧缩放后的宽(256*16/9≈455)。
  assert.ok(meta.cellW < 200, `横向留白应被裁掉，cell 宽应 <200，实得 ${meta.cellW}`);
  // 角色是竖向细长：高 > 宽。
  assert.ok(meta.cellH > meta.cellW, `角色应竖向细长(高>宽)，实得 ${meta.cellW}x${meta.cellH}`);
});
