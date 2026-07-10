import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { pickTaskCandidate, completeTaskOnEvent } from '../src/tasks.ts';
import { INITIAL_FLOWERS, type ActiveTask, type Character } from '../src/types.ts';

function seed(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  for (const [id, name] of [['n1', '小蓝'], ['n2', '小绿']] as const) {
    const c: Character = {
      id, worldId: 'w1', isFairy: false, name, personality: 'p', voiceId: 'v',
      appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
      memory: [], chatHistory: [], state: 'idle',
      behaviorScript: { commands: [], loop: false },
      position: { tileX: 1, tileY: 1 }, abilities: [], relationships: {},
    };
    s.addCharacter(c);
  }
  s.setLocations('w1', ['池塘']);
  return s;
}

const always = () => 0; // 确定性 rand：总取第一个候选

/** 按委托类型造出能让它判定完成的事件（类型由 pickTaskCandidate 的候选顺序决定，别写死）。 */
function eventFor(t: ActiveTask) {
  if (t.type === 'visit') return { kind: 'visit_done', locationName: t.locationName };
  if (t.type === 'bring') return { kind: 'bring_done', targetName: t.targetName };
  return { kind: 'deliver_done', targetName: t.targetName };
}

test('A 接了委托，B 仍能从 NPC 那里接到委托（改动前 B 会被永久阻塞）', () => {
  const s = seed();

  const forA = pickTaskCandidate('w1', 'n1', 'A', s, always);
  assert.ok(forA, 'A 应能接到委托');
  s.setActiveTask('w1', 'A', forA);

  // A 已有委托：A 自己不再拿到新的
  assert.equal(pickTaskCandidate('w1', 'n1', 'A', s, always), null, 'A 手上有委托，不再派新的');

  // 关键：B 不该被 A 的委托挡住
  const forB = pickTaskCandidate('w1', 'n1', 'B', s, always);
  assert.ok(forB, 'B 应该也能接到委托——这正是本次改动要修的');
});

test('完成委托只结算自己的：A 完成不清 B 的委托、不给 B 盖章', () => {
  const s = seed();
  const forA = pickTaskCandidate('w1', 'n1', 'A', s, always)!;
  const forB = pickTaskCandidate('w1', 'n1', 'B', s, always)!;
  s.setActiveTask('w1', 'A', forA);
  s.setActiveTask('w1', 'B', forB);

  const done = completeTaskOnEvent('w1', 'A', eventFor(forA), s);

  assert.ok(done, 'A 的委托应被判定完成');
  assert.equal(s.getActiveTask('w1', 'A'), null, 'A 的委托已清');
  assert.ok(s.getActiveTask('w1', 'B'), 'B 的委托还在');

  assert.equal(s.getWallet('w1', 'A').stampsTotal, 1, 'A 盖了一章');
  assert.equal(s.getWallet('w1', 'B').stampsTotal, 0, 'B 没被顺带盖章');
  assert.equal(s.getWallet('w1', 'B').flowers, INITIAL_FLOWERS);
});

test('别人的完成事件不能清掉我的委托', () => {
  const s = seed();
  const forA = pickTaskCandidate('w1', 'n1', 'A', s, always)!;
  s.setActiveTask('w1', 'A', forA);

  // B 手上没委托，B 触发完成事件 → 无事发生
  const done = completeTaskOnEvent('w1', 'B', eventFor(forA), s);
  assert.equal(done, null, 'B 没有委托，不该判定完成');
  assert.ok(s.getActiveTask('w1', 'A'), 'A 的委托毫发无损');
});
