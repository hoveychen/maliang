import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { decodeTerrain, TERRAIN_VERSION } from '../src/terrain.ts';
import { BUILTIN_ITEMS, validateTerrainItems, resolveBuiltin, buildStaticOccupancy, getBuiltinItem } from '../src/items.ts';

/**
 * 打包默认矩阵（assets/terrain/*.mltr，Godot 导出工具产）跨端验收：
 * 服务端解码器 + 物品语义校验必须原样通过——这是「导出工具/客户端/服务端
 * 三方对同一格式」的集成对拍，任何一方改了编码都会在这里炸。
 */

const ASSETS = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'assets', 'terrain');

for (const scene of ['village', 'forest'] as const) {
  test(`${scene}.mltr：v2 解码 + 物品语义校验通过`, () => {
    const buf = new Uint8Array(readFileSync(join(ASSETS, `${scene}.mltr`)));
    const t = decodeTerrain(buf);
    assert.equal(buf[4], TERRAIN_VERSION);
    assert.ok(t.palette.length > 0, 'palette 非空');
    for (const id of t.palette) assert.ok(getBuiltinItem(id), `palette 项 ${id} 是内置实体`);

    assert.doesNotThrow(() => validateTerrainItems(t, resolveBuiltin));

    const items = t.itemRef.reduce((s, v) => s + (v === 0 ? 0 : 1), 0);
    assert.ok(items > 500, `物品总数 ${items} > 500`);
    const occ = buildStaticOccupancy(t, resolveBuiltin);
    assert.ok(occ.reduce((s, v) => s + v, 0) > 0, '派生占用非空');
  });
}

test('builtin_items.json（客户端打包副本）与 BUILTIN_ITEMS 逐项一致', () => {
  // 客户端离线路径吃打包 JSON；服务端是常量单源。两边漂移 = 占地/渲染语义分叉，这里锁死。
  const packed = JSON.parse(readFileSync(join(ASSETS, 'builtin_items.json'), 'utf-8')) as unknown[];
  assert.deepEqual(packed, BUILTIN_ITEMS.map((d) => ({ ...d })));
});

test('village.mltr：地标锚点在约定位置（well/windmill）', () => {
  const buf = new Uint8Array(readFileSync(join(ASSETS, 'village.mltr')));
  const t = decodeTerrain(buf);
  const idAt = (x: number, y: number) => {
    const r = t.itemRef[y * t.gridW + x]!;
    return r === 0 ? '' : t.palette[r - 1]!;
  };
  assert.equal(idAt(37, 37), 'well');
  assert.equal(idAt(59, 54), 'windmill');
  assert.equal(idAt(31, 31), 'house_0');
});
