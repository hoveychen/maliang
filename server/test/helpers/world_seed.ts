// 测试用世界 seed helper。
//
// P6 前，很多测试靠 `await app.inject({ GET /worlds/default })` 的副作用来「建 default 世界 + 种点点」
// 做 setup（那条分支已随 P6 退役 default 删除，见 server.ts）。这些测试并不验证世界模板架构——它们只需要
// 「一个含点点的世界」跑语音会话/造物/对话。P6 后改用本 helper 显式建世界，不再依赖已删除的自动重建分支。
//
// 'default' 在此仅作一个【普通】世界名（不再特殊），保留它是为了不动测试体里大量的 `worldId: 'default'` 字面量。
import { seedFairy } from '../../src/server.ts';
import type { WorldStore } from '../../src/persistence.ts';

/** 显式建一个含点点的世界（默认名 'default'）——复刻 P6 前 GET /worlds/default 的建世界+种点点副作用。 */
export function seedFairyWorld(store: WorldStore, worldId = 'default'): void {
  if (!store.worldExists(worldId)) store.createWorld(worldId);
  if (!store.listCharacters(worldId).some((c) => c.isFairy)) {
    store.addCharacter(seedFairy(worldId));
  }
}
