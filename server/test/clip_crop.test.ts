import { test } from 'node:test';
import assert from 'node:assert/strict';
import { computeHorizontalCrop, type RgbaFrame } from '../src/clip_video.ts';

const GREEN = [0, 177, 64];   // 0x00b140 绿幕
const RED = [255, 0, 0];      // 角色内容（非绿主导）

/** 造一帧 WxH 绿底，列区间 [cx0,cx1] 填红（=角色横向内容）。 */
function frame(W: number, H: number, cx0: number, cx1: number): RgbaFrame {
  const data = new Uint8Array(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const p = (y * W + x) * 4;
      const c = x >= cx0 && x <= cx1 ? RED : GREEN;
      data[p] = c[0]!; data[p + 1] = c[1]!; data[p + 2] = c[2]!; data[p + 3] = 255;
    }
  }
  return { width: W, height: H, data };
}

test('computeHorizontalCrop: 居中窄内容 → 只裁宽到内容+边距(偶数对齐)', () => {
  // 200 宽,内容 x[80,119](居中 40px),pad=round(200*0.02)=4 → x0=76,x1=123,w=48
  const crop = computeHorizontalCrop([frame(200, 20, 80, 119)]);
  assert.ok(crop, '应裁');
  assert.equal(crop!.x % 2, 0, 'x 偶数');
  assert.equal(crop!.w % 2, 0, 'w 偶数');
  // 内容 [80,119] 必须完整落在裁剪窗内
  assert.ok(crop!.x <= 80 && crop!.x + crop!.w - 1 >= 119, '裁剪窗含全部内容');
  assert.ok(crop!.w < 200 * 0.88, '确实裁掉了绿边');
});

test('computeHorizontalCrop: 多帧取并集(角色横向摆动)', () => {
  // 帧A内容偏左[60,100],帧B偏右[100,140] → 并集[60,140]
  const crop = computeHorizontalCrop([frame(200, 20, 60, 100), frame(200, 20, 100, 140)]);
  assert.ok(crop);
  assert.ok(crop!.x <= 60 && crop!.x + crop!.w - 1 >= 140, '裁剪窗含两帧并集');
});

test('computeHorizontalCrop: 全绿帧 → null(不裁)', () => {
  const f = frame(200, 20, 999, 999); // 无红=全绿
  assert.equal(computeHorizontalCrop([f]), null);
});

test('computeHorizontalCrop: 内容已占满宽(>88%) → null(不值得裁)', () => {
  const crop = computeHorizontalCrop([frame(200, 20, 10, 189)]); // 90% 宽
  assert.equal(crop, null);
});

test('computeHorizontalCrop: 无帧 → null', () => {
  assert.equal(computeHorizontalCrop([]), null);
});

test('computeHorizontalCrop: 贴左边缘内容 → x 钳到 0、偶数', () => {
  const crop = computeHorizontalCrop([frame(200, 20, 0, 30)]);
  assert.ok(crop);
  assert.equal(crop!.x, 0);
  assert.equal(crop!.w % 2, 0);
  assert.ok(crop!.x + crop!.w - 1 >= 30, '含右边界内容');
});
