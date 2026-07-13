import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { WISHES, WISH_ABILITIES, IDLE_DOING, wishFor, pickLeak, pickThanks } from '../src/wishes.ts';

// ── 词库纪律：漏话必须是自言自语，不能是广告 ────────────────────────────
// 这是整个设计的成败线（见 docs/wish-leak-design.md §2）。一旦有人往库里加了
// 「要不要我帮你造呀？」这种句子，机制就退回成「仙子打广告」——测试直接拦住。

test('漏话不含广告腔——没有「你可以」「要不要」「告诉我」这类招揽话术', () => {
  const banned = ['你可以', '要不要', '告诉我', '跟我说', '想不想', '我带你', '我帮你'];
  for (const wish of Object.values(WISHES)) {
    for (const line of wish.leaks) {
      for (const b of banned) {
        assert.ok(!line.includes(b), `漏话「${line}」含招揽话术「${b}」——这是广告不是自言自语`);
      }
    }
  }
  for (const line of IDLE_DOING) {
    for (const b of banned) {
      assert.ok(!line.includes(b), `氛围自语「${line}」含招揽话术「${b}」`);
    }
  }
});

test('每个心愿都配齐了漏话/背景/道谢', () => {
  for (const [key, wish] of Object.entries(WISHES)) {
    assert.equal(wish.ability, key, `${key} 的 ability 字段与键不一致`);
    assert.ok(wish.leaks.length >= 2, `${key} 至少要有 2 条漏话，否则第二次路过就重样`);
    assert.ok(wish.context.length > 0, `${key} 缺 prompt 背景——被搭话时接不上自己的心愿`);
    assert.ok(wish.thanks.length >= 1, `${key} 缺道谢词——兑现闭环断了`);
  }
});

// ── 认领：稳定 + 已发现的不再提 ────────────────────────────────────────

test('同一村民的心愿是稳定的——第二次路过听见的还是同一个念想', () => {
  const first = wishFor('npc-abc', []);
  for (let i = 0; i < 10; i++) {
    assert.equal(wishFor('npc-abc', [])?.ability, first?.ability);
  }
});

test('不同村民会认领到不同心愿（不是全世界一起念叨同一件事）', () => {
  const got = new Set<string>();
  for (let i = 0; i < 40; i++) got.add(wishFor(`npc-${i}`, [])?.ability ?? '');
  assert.ok(got.size >= 3, `40 个村民只出现了 ${got.size} 种心愿，分布太集中`);
});

test('已发现的玩法不再被任何村民认领', () => {
  const discovered = ['create_prop', 'play_game'];
  for (let i = 0; i < 40; i++) {
    const w = wishFor(`npc-${i}`, discovered);
    assert.ok(w !== null);
    assert.ok(!discovered.includes(w.ability), `村民 npc-${i} 还在念叨已发现的 ${w.ability}`);
  }
});

test('玩法全被发现后不再有心愿——村民回落纯氛围自语，不再啰嗦', () => {
  const all = [...WISH_ABILITIES];
  assert.equal(wishFor('npc-abc', all), null);
  const leak = pickLeak('npc-abc', all, () => 0);
  assert.ok(IDLE_DOING.includes(leak), `池耗尽时应回落 IDLE_DOING，却拿到「${leak}」`);
});

test('pickLeak 取的是该村民自己心愿里的话', () => {
  const wish = wishFor('npc-abc', [])!;
  const leak = pickLeak('npc-abc', [], () => 0);
  assert.equal(leak, wish.leaks[0]);
});

test('pickThanks 取自该心愿的道谢词', () => {
  const wish = WISHES.create_prop!;
  assert.equal(pickThanks(wish, () => 0), wish.thanks[0]);
});

// ── discovered 持久化 ──────────────────────────────────────────────────

test('discovered：首次发现返回 true 并落库，重复发现返回 false 不重复写', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  assert.deepEqual(store.getDiscovered('w1', 'p1'), []);

  assert.equal(store.addDiscovered('w1', 'p1', 'create_prop'), true);
  assert.deepEqual(store.getDiscovered('w1', 'p1'), ['create_prop']);

  assert.equal(store.addDiscovered('w1', 'p1', 'create_prop'), false, '重复发现应返回 false（否则会重复盖章/重复道谢）');
  assert.deepEqual(store.getDiscovered('w1', 'p1'), ['create_prop']);

  assert.equal(store.addDiscovered('w1', 'p1', 'play_game'), true);
  assert.deepEqual(store.getDiscovered('w1', 'p1'), ['create_prop', 'play_game']);
});

test('discovered 按 (world, player) 分——换个玩家/换个世界是各自的进度', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  store.createWorld('w2');
  store.addDiscovered('w1', 'p1', 'create_prop');
  assert.deepEqual(store.getDiscovered('w1', 'p2'), [], '另一个玩家不该继承 p1 的发现');
  assert.deepEqual(store.getDiscovered('w2', 'p1'), [], '另一个世界不该继承 w1 的发现');
});
