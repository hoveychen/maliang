// 点点的人设（fairy-persona P1，见 docs/fairy-persona-design.md）：
// 她从「小神仙」（一个没有欲望、只有 API 的工具人）改成神笔的笔灵「点点」。
// 名字曾经三分（数据 name='小神仙' / 台词自称「小仙子」/ 注释「仙女」），现在单一来源 FAIRY_NAME。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { seedFairy } from '../src/server.ts';
import { FAIRY_NAME, FAIRY_PERSONALITY, LOCOMOTION_ABILITIES, effectiveAbilities } from '../src/types.ts';

test('seedFairy：新世界的仙子叫点点，人设是笔灵而不是能力说明书', () => {
  const f = seedFairy('default');
  assert.equal(f.name, FAIRY_NAME);
  assert.equal(f.name, '点点', '名字定稿为「点点」——一笔落下就是一个点');

  // 人设必须带三个欲望锚点 + 第三人称自称。旧人设「温柔的小神仙，能按小朋友的想法创造新伙伴」
  // 有一半在写 API——那是她读起来像工具人的根因。
  assert.match(f.personality, /第三人称/, '她第三人称自称（3-5 岁本来就这么说话）');
  assert.match(f.personality, /笔没有腿/, '不会走路是设定（笔灵），不是技术约束');
  assert.match(f.personality, /好看吗/, '锚点①：爱显摆手艺、做完求夸');
  assert.match(f.personality, /怕水/, '锚点③：怕水会化开——孩子照顾她的情感杠杆');
  assert.match(f.personality, /惊叹/, '锚点②：容易惊叹');
  assert.doesNotMatch(f.personality, /创造新伙伴/, '人设里不该再有能力说明书');
});

test('seedFairy：abilities 不再带永远被剥夺的 move_to / deliver_message', () => {
  const f = seedFairy('default');
  for (const a of ['move_to', 'deliver_message']) {
    assert.ok(!f.abilities.includes(a), `${a} 是历史残留：effectiveAbilities 恒剔除，给了也兑现不了`);
  }
  assert.ok(f.abilities.includes('create_character') && f.abilities.includes('guide_to'), '看家本领仍在');
});

test('三层移动封锁未被人设改动破坏：她拿不到任何需要走过去的能力', () => {
  const f = seedFairy('default');
  const eff = effectiveAbilities(f);
  for (const a of LOCOMOTION_ABILITIES) {
    assert.ok(!eff.includes(a), `仙子的 prompt 里绝不能出现 ${a}——LLM 会承诺「我们去风车那儿」然后人纹丝不动`);
  }
  assert.ok(eff.includes('guide_to'), '引路是她唯一的位移：走路的是小朋友，她只飞在前面领');
});

test('存量迁移：老库里叫「小神仙」的仙子，重开后改名点点并换上新人设（幂等，不动非仙子）', () => {
  const dir = join(tmpdir(), `maliang-fairy-persona-${process.hrtime.bigint()}`);
  rmSync(dir, { recursive: true, force: true });
  try {
    const store = new WorldStore(dir);
    store.createWorld('default');

    // 模拟迁移前的存量数据：旧名字 + 旧人设 + 带着两个永远被剥夺的能力
    const old = seedFairy('default');
    old.id = 'old-fairy';
    old.name = '小神仙';
    old.personality = '温柔的小神仙，能按小朋友的想法创造新伙伴。';
    old.abilities = ['move_to', 'deliver_message', 'create_character', 'create_prop'];
    store.addCharacter(old);

    // 一个同名的普通村民（非仙子）：迁移绝不该动它
    const villager = seedFairy('default');
    villager.id = 'villager';
    villager.isFairy = false;
    villager.name = '小神仙';
    villager.personality = '温柔的小神仙，能按小朋友的想法创造新伙伴。';
    store.addCharacter(villager);

    // 重开库 → 触发启动迁移
    const store2 = new WorldStore(dir);
    const f = store2.getCharacter('default', 'old-fairy')!;
    assert.equal(f.name, FAIRY_NAME, '存量仙子应改名点点');
    assert.equal(f.personality, FAIRY_PERSONALITY, '人设应换成笔灵版');
    assert.ok(!f.abilities.includes('move_to'), '顺手清掉永远被剥夺的 move_to');
    assert.ok(!f.abilities.includes('deliver_message'), '顺手清掉 deliver_message');
    assert.ok(f.abilities.includes('create_character'), '真能兑现的能力不丢');

    const v = store2.getCharacter('default', 'villager')!;
    assert.equal(v.name, '小神仙', '非仙子不该被改名');
    assert.equal(v.personality, '温柔的小神仙，能按小朋友的想法创造新伙伴。', '非仙子的人设不该被动');

    // 幂等：再重开一次不变
    const store3 = new WorldStore(dir);
    const f3 = store3.getCharacter('default', 'old-fairy')!;
    assert.equal(f3.name, FAIRY_NAME);
    assert.equal(f3.personality, FAIRY_PERSONALITY);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
