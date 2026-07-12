// 角色立绘锚点（character-anchors P1，docs/character-anchors-design.md）：
// vision 回答解析、像素级合法性校验与逐点降级、alpha 兜底几何、
// createCharacter 编排接入（mock 全链路）、/admin/detect-anchors 回填幂等。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { parseAnchorAnswer } from '../src/adapters/openrouter_anchors.ts';
import { alphaHeadTop, alphaHandFallback, nearOpaque, validateAnchors, detectCharacterAnchors } from '../src/anchors.ts';
import { decode } from '../src/adapters/chroma_cutout.ts';
import { createCharacter } from '../src/orchestrator.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import type { ImageBlob } from '../src/adapters/types.ts';

/** 合成立绘：100×100 透明底，身体矩形 x∈[30,70] y∈[10,90] 不透明（头顶行 y=10 中心 x=50）。 */
function bodyPng(): ImageBlob {
  const png = new PNG({ width: 100, height: 100 });
  for (let y = 10; y <= 90; y++) {
    for (let x = 30; x <= 70; x++) {
      const i = (y * 100 + x) * 4;
      png.data[i] = 200;
      png.data[i + 1] = 100;
      png.data[i + 2] = 50;
      png.data[i + 3] = 255;
    }
  }
  return { bytes: new Uint8Array(PNG.sync.write(png)), mime: 'image/png' };
}

// ── parseAnchorAnswer ──────────────────────────────────────────────────────

test('parseAnchorAnswer: 合法 JSON（含前后废话）→ 三点归一化；缺点/越界/非 JSON → null', () => {
  const ok = parseAnchorAnswer(
    '好的，检测结果如下：[{"label":"head_top","x":500,"y":50},{"label":"left_hand","x":200,"y":550},{"label":"right_hand","x":800,"y":550}] 完毕',
  );
  assert.deepEqual(ok, { headTop: { x: 0.5, y: 0.05 }, handL: { x: 0.2, y: 0.55 }, handR: { x: 0.8, y: 0.55 } });

  assert.equal(parseAnchorAnswer('[{"label":"head_top","x":500,"y":50}]'), null, '缺手');
  assert.equal(parseAnchorAnswer('[{"label":"head_top","x":1500,"y":50},{"label":"left_hand","x":1,"y":1},{"label":"right_hand","x":1,"y":1}]'), null, 'x 越界的点被丢 → 缺 head_top');
  assert.equal(parseAnchorAnswer('看不出来'), null);
  assert.equal(parseAnchorAnswer('[not json'), null);
});

// ── alpha 兜底几何 ─────────────────────────────────────────────────────────

test('alphaHeadTop / alphaHandFallback：合成身体矩形的几何正确', () => {
  const r = decode(bodyPng().bytes);
  const head = alphaHeadTop(r);
  assert.ok(Math.abs(head.x - 50 / 99) < 0.01, `头顶 x≈中心，got ${head.x}`);
  assert.ok(Math.abs(head.y - 10 / 99) < 0.01, `头顶 y≈首个不透明行，got ${head.y}`);

  const hl = alphaHandFallback(r, 'L');
  const hr = alphaHandFallback(r, 'R');
  assert.equal(hl.y, 0.55);
  assert.ok(Math.abs(hl.x - (30 + 5) / 99) < 0.02, `左手=左缘内收 5%，got ${hl.x}`);
  assert.ok(Math.abs(hr.x - (70 - 5) / 99) < 0.02, `右手=右缘内收 5%，got ${hr.x}`);
});

test('nearOpaque：身体上为真，空白角为假', () => {
  const r = decode(bodyPng().bytes);
  assert.equal(nearOpaque(r, { x: 0.5, y: 0.5 }), true);
  assert.equal(nearOpaque(r, { x: 0.02, y: 0.98 }), false);
});

// ── validateAnchors 逐点降级 ───────────────────────────────────────────────

test('validateAnchors：三点原生合法 → source=vision 原样保留', () => {
  const r = decode(bodyPng().bytes);
  const a = validateAnchors(r, { headTop: { x: 0.5, y: 0.12 }, handL: { x: 0.32, y: 0.55 }, handR: { x: 0.68, y: 0.55 } });
  assert.equal(a.source, 'vision');
  assert.deepEqual(a.headTop, { x: 0.5, y: 0.12 });
});

test('validateAnchors：点飞空白/headTop 在下半部 → 该点降级兜底，source=fallback', () => {
  const r = decode(bodyPng().bytes);
  // headTop 点到空白角 → alpha 兜底；手合法保留
  const a = validateAnchors(r, { headTop: { x: 0.02, y: 0.02 }, handL: { x: 0.32, y: 0.55 }, handR: { x: 0.68, y: 0.55 } });
  assert.equal(a.source, 'fallback');
  assert.ok(Math.abs(a.headTop.x - 50 / 99) < 0.01, '降级到 alpha 头顶');
  assert.deepEqual(a.handL, { x: 0.32, y: 0.55 }, '合法点原样保留');

  // headTop 在身体上但 y>0.5（"头顶"点到脚上）→ 语义非法降级
  const b = validateAnchors(r, { headTop: { x: 0.5, y: 0.8 }, handL: { x: 0.32, y: 0.55 }, handR: { x: 0.68, y: 0.55 } });
  assert.equal(b.source, 'fallback');
  assert.ok(b.headTop.y < 0.5);
});

test('validateAnchors(raw=null) / detectCharacterAnchors 检测失败：三点全兜底', async () => {
  const r = decode(bodyPng().bytes);
  const a = validateAnchors(r, null);
  assert.equal(a.source, 'fallback');

  const failing = { async detectAnchors() { return null; } };
  const d = await detectCharacterAnchors(failing, bodyPng());
  assert.ok(d);
  assert.equal(d!.source, 'fallback');

  const badImage = await detectCharacterAnchors(failing, { bytes: new Uint8Array([1, 2, 3]), mime: 'image/png' });
  assert.equal(badImage, null, '解码失败返回 null 不 throw');
});

// ── 编排接入：造角色即带锚点 ────────────────────────────────────────────────

test('createCharacter（mock 全链路）：appearance.anchors 落库且确定性', async () => {
  const store = new WorldStore();
  store.createWorld('default');
  const c = await createCharacter(
    { worldId: 'default', intentText: '造一只小兔子' },
    createMockAdapters(), store,
  );
  const anchors = c.appearance.anchors;
  assert.ok(anchors, '造角色即带锚点');
  // mock 立绘是 1×1 全透明 → mock 点全部过不了 nearOpaque → 全兜底（确定性值）
  assert.equal(anchors!.source, 'fallback');
  assert.deepEqual(anchors!.headTop, { x: 0.5, y: 0.02 });
  assert.equal(anchors!.handL.y, 0.55);
  const stored = store.listCharacters('default').find((x) => x.id === c.id);
  assert.deepEqual(stored?.appearance.anchors, anchors, '锚点随角色行落库');
});
