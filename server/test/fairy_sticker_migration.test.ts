// 存量仙子能力回填（fairy-stickers P5）：seedFairy 只在建世界时贑，老库里的仙子缺 create_sticker。
// #migrateFairyStickerAbility 在重开库时给所有 isFairy 角色补上（幂等，不动非仙子）。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { seedFairy } from '../src/server.ts';

test('存量仙子迁移：老库缺 create_sticker 的仙子重开后自动补上（幂等，不动非仙子）', () => {
  const dir = join(tmpdir(), `maliang-fairy-mig-${process.hrtime.bigint()}`);
  rmSync(dir, { recursive: true, force: true });
  try {
    const store = new WorldStore(dir);
    store.createWorld('default');
    // 造一个「老」仙子：能力里没有 create_sticker（模拟迁移前的存量数据）
    const oldFairy = seedFairy('default');
    oldFairy.id = 'old-fairy';
    oldFairy.abilities = ['move_to', 'deliver_message', 'create_character', 'create_prop'];
    store.addCharacter(oldFairy);
    // 一个普通村民（非仙子）：迁移不该动它
    const villager = seedFairy('default');
    villager.id = 'villager';
    villager.isFairy = false;
    villager.abilities = ['move_to'];
    store.addCharacter(villager);

    // 重开库 → 触发启动迁移
    const store2 = new WorldStore(dir);
    const f = store2.getCharacter('default', 'old-fairy')!;
    assert.ok(f.abilities.includes('create_sticker'), '存量仙子应补上 create_sticker');
    assert.equal(f.abilities.filter((a) => a === 'create_sticker').length, 1, '只补一条，不重复');
    // 原有能力保留
    assert.ok(f.abilities.includes('create_character') && f.abilities.includes('create_prop'), '原能力不丢');
    const v = store2.getCharacter('default', 'villager')!;
    assert.ok(!v.abilities.includes('create_sticker'), '非仙子不该被动');

    // 幂等：再重开一次不重复补
    const store3 = new WorldStore(dir);
    const f3 = store3.getCharacter('default', 'old-fairy')!;
    assert.equal(f3.abilities.filter((a) => a === 'create_sticker').length, 1, '再次重开仍只一条');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
