import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PNG } from 'pngjs';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';
import type { SpriteSheetMeta } from '../src/sprite_sheet.ts';

const FAKE_META: SpriteSheetMeta = {
  cols: 2, rows: 2, frameCount: 3, fps: 8, cellW: 20, cellH: 30, width: 40, height: 60,
};
const fakeSheet = async (): Promise<{ atlas: { bytes: Uint8Array; mime: string }; meta: SpriteSheetMeta }> => ({
  atlas: { bytes: Uint8Array.from([1, 2, 3]), mime: 'image/png' },
  meta: FAKE_META,
});

/** 100x100 透明画布，中间 (40..59, 30..69) 一块不透明红块 —— 模拟带大片留白的存量立绘。 */
function untrimmedSprite(): Uint8Array {
  const png = new PNG({ width: 100, height: 100 });
  for (let y = 30; y < 70; y++) {
    for (let x = 40; x < 60; x++) {
      const i = (y * 100 + x) * 4;
      png.data[i] = 220; png.data[i + 1] = 40; png.data[i + 2] = 40; png.data[i + 3] = 255;
    }
  }
  return new Uint8Array(PNG.sync.write(png));
}

function seedChar(store: WorldStore, worldId: string, id: string, spriteAsset: string): Character {
  const c: Character = {
    id, worldId, isFairy: false, name: '舞舞兔', personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: 'a bunny', spriteAsset, scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: ['move_to'], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

test('retrim-sprites: token 门禁 + 存量立绘裁边、更新 spriteAsset、触发动画重生成', async (t) => {
  const store = new WorldStore();
  store.createWorld('w1');
  const oldHash = store.putAsset({ bytes: untrimmedSprite(), mime: 'image/png' });
  seedChar(store, 'w1', 'c1', oldHash);
  const app = await buildServer({ adapters: createMockAdapters(), store, toSpriteSheet: fakeSheet });
  t.after(() => app.close());

  const url = '/admin/retrim-sprites';

  // 未配置 token → 403
  delete process.env.MALIANG_ADMIN_TOKEN;
  assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);

  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  try {
    // token 错 → 403
    assert.equal(
      (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode,
      403,
    );

    // token 对 → 裁边
    const res = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res.statusCode, 200);
    const body = res.json() as {
      count: number; regenerated: number;
      characters: { name: string; prev: string; spriteAsset: string; changed: boolean }[];
    };
    assert.equal(body.count, 1);
    const rec = body.characters[0]!;
    assert.equal(rec.prev, oldHash);
    assert.ok(rec.changed, '带留白的立绘应被裁 → changed=true');
    assert.notEqual(rec.spriteAsset, oldHash, 'spriteAsset 应指向裁后新 hash');
    assert.equal(body.regenerated, 1, '应触发一次动画重生成');

    // 角色记录已更新
    assert.equal(store.getCharacter('w1', 'c1')!.appearance.spriteAsset, rec.spriteAsset);

    // 裁后资产确实更小（内容盒 20x40 + 2*8 pad = 36x56，远小于原 100x100）
    const trimmed = PNG.sync.read(Buffer.from(store.getAsset(rec.spriteAsset)!.bytes));
    assert.ok(trimmed.width < 100 && trimmed.height < 100, `裁后应变小，得 ${trimmed.width}x${trimmed.height}`);
    assert.ok(40 / trimmed.height > 0.6, '裁后角色应占满多数高度');

    // 幂等：再跑一次，此时立绘已贴身 → 不再 changed、不再重生成
    const again = (await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } })).json() as {
      characters: { changed: boolean }[]; regenerated: number;
    };
    assert.equal(again.characters[0]!.changed, false, '已贴身立绘二次运行不应再变');
    assert.equal(again.regenerated, 0, '已贴身立绘不应再触发重生成');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
