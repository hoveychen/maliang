// 存量孩子造物去黑边迁移（creation-outline-off P2，见 #migrateCreationOutlineOff）：
// 服务端曾把造物 spec 的 outline 默认成 0.04，写进了 items 表的 data JSON；客户端读 outline>0
// 会挂 inverted-hull 黑边描边 pass。老板 2026-07-23 拍板去黑边：新造物由 sanitizeSdfPropSpec
// 硬置 0，存量造物由本迁移在开库时把 sdf_inline 行的 spec.outline 归 0（幂等，只碰 outline）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { creationItemDef } from '../src/items.ts';
import { fallbackSdfPropSpec } from '../src/sdf_prop.ts';
import type { SdfPropSpec } from '../src/sdf_prop.ts';

test('存量迁移：孩子造物 spec.outline>0 开库后归 0（幂等，不动其余 spec）', () => {
  const dir = join(tmpdir(), `maliang-creation-outline-${process.hrtime.bigint()}`);
  rmSync(dir, { recursive: true, force: true });
  try {
    const store = new WorldStore(dir);
    const w = store.createWorld().id;

    // 迁移前的存量造物：spec.outline = 0.04（旧服务端默认，直接塞进 items 行）
    store.upsertItem(creationItemDef(w, 'legacy-prop', { ...fallbackSdfPropSpec('小车'), outline: 0.04 }));
    // 已是 0 的造物：迁移应原样保持（不误伤 + 幂等控制点）
    store.upsertItem(creationItemDef(w, 'already-off', { ...fallbackSdfPropSpec('小球'), outline: 0 }));

    // 重开库 → 触发启动迁移
    const store2 = new WorldStore(dir);
    const migrated = store2.getItemDef(w, 'legacy-prop')!.spec as SdfPropSpec;
    assert.equal(migrated.outline, 0, '存量造物 outline 应归 0（去黑边）');
    assert.equal(migrated.name, '小车', '迁移只碰 outline，不动其余 spec 字段');
    assert.equal((store2.getItemDef(w, 'already-off')!.spec as SdfPropSpec).outline, 0, '已 0 的造物保持 0');

    // 幂等：再重开一次仍是 0（无行可迁）
    const store3 = new WorldStore(dir);
    assert.equal((store3.getItemDef(w, 'legacy-prop')!.spec as SdfPropSpec).outline, 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
