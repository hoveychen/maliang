import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { pickTaskCandidate } from '../src/tasks.ts';
import { REQUIRED_GRID } from '../src/terrain.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character } from '../src/types.ts';

function char(worldId: string, id: string, sceneId: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
}

function scene(s: WorldStore, sceneId: string, poiNames: string[]): void {
  s.upsertScene({
    worldId: 'w1', sceneId, name: sceneId, terrainAsset: 'h-' + sceneId, gridTiles: REQUIRED_GRID, terrainVersion: 1,
    pois: poiNames.map((n, i) => ({ tile: [i, i] as [number, number], radius: 5, trigger: 't' + i, name: n, aliases: [] })),
    portals: [],
  });
}

test('getLocations 按场景：只返回该场景的地点', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  scene(s, DEFAULT_SCENE, ['池塘', '广场']);
  scene(s, 'forest', ['树屋']);

  assert.deepEqual(s.getLocations('w1', DEFAULT_SCENE).sort(), ['广场', '池塘']);
  assert.deepEqual(s.getLocations('w1', 'forest'), ['树屋']);
  assert.deepEqual(s.getLocations('w1').sort(), ['广场', '树屋', '池塘'], '不传场景仍摊平全世界(兼容)');
});

test('getLocations 按场景：世界有场景但该场景无 POI → 空，不泄漏别场景', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  scene(s, DEFAULT_SCENE, []); // village 无 POI
  scene(s, 'forest', ['树屋']);
  assert.deepEqual(s.getLocations('w1', DEFAULT_SCENE), [], 'village 无地点，不该冒出 forest 的树屋');
});

test('getLocations 按场景：世界完全没入库场景 → 回退客户端上报', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.setLocations('w1', ['池塘', '风车']);
  assert.deepEqual(s.getLocations('w1', DEFAULT_SCENE), ['池塘', '风车']);
});

test('pickTaskCandidate 按场景：npc 所在场景无其他角色/地点 → null（不跨场景指人指地）', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  scene(s, DEFAULT_SCENE, []); // village 无 POI
  scene(s, 'forest', ['树屋']);
  s.addCharacter(char('w1', 'v-npc', DEFAULT_SCENE)); // village 里只有委托人自己
  s.addCharacter(char('w1', 'f-1', 'forest'));        // 别的角色在森林

  // 按 village 过滤：村里没别人、没地点 → 生不出委托（尽管森林里有 f-1 和树屋）
  assert.equal(pickTaskCandidate('w1', 'v-npc', 'A', s, () => 0, DEFAULT_SCENE), null);
  // 不传场景（全世界）→ 能挑到森林的目标/地点，证明差异确实来自场景过滤
  assert.notEqual(pickTaskCandidate('w1', 'v-npc', 'A', s, () => 0), null);
});

test('pickTaskCandidate 按场景：同场景有目标时正常出委托，目标只来自本场景', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  scene(s, DEFAULT_SCENE, ['广场']);
  scene(s, 'forest', ['树屋']);
  s.addCharacter(char('w1', 'v-npc', DEFAULT_SCENE));
  s.addCharacter(char('w1', 'v-2', DEFAULT_SCENE));
  s.addCharacter(char('w1', 'f-1', 'forest'));

  // rand=0 → 选 types[0]=deliver → target=others[0]。others 只能是 village 的 v-2，绝不会是 f-1。
  const t = pickTaskCandidate('w1', 'v-npc', 'A', s, () => 0, DEFAULT_SCENE);
  assert.ok(t, '同场景有目标应出委托');
  assert.equal(t!.targetName, 'v-2', '目标必须是本场景角色');
});
