// 造角色的降生:新角色要落在【发起者所在场景/身边】,并让同场景其他人实时看见。
// 旧行为:createCharacter 既不传 sceneId 也不传 position → 一律落到 DEFAULT_SCENE 的世界中心;
// gen_complete 只单播给发起者 → 别人要重进场景才看得到。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldHub } from '../src/world_hub.ts';
import { DEFAULT_SCENE } from '../src/types.ts';

function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const conn = (connKey: string) => {
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: object) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub);
    return { sent, say, ofType: (t: string) => sent.filter((m) => m.type === t) };
  };
  return { store, hub, conn };
}

/** setPlayerTile 要求玩家档案先存在（persistence.ts），故 world_info 必须带 profile。 */
function profile(name: string) {
  return { name, nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
}

test('造角色：落在发起者所在场景与身边，而不是 village 的世界中心', async () => {
  const { store, conn } = rig();
  store.setFlowers('w1', 'pa', 9);
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'forest', profile: profile('小明') });
  assert.equal(store.setPlayerTile('w1', 'forest', 'pa', { tileX: 40, tileY: 41 }), true, '档案已建，落位应成功');

  await a.say({ type: 'create_character_request', worldId: 'w1', playerId: 'pa', intentText: '一只会飞的小猫' });

  const done = a.ofType('gen_complete');
  assert.equal(done.length, 1, '应造出角色');
  const ch = store.getCharacter('w1', done[0].character.id);
  assert.ok(ch);
  assert.equal(ch.sceneId, 'forest', '角色该落在发起者所在场景');
  assert.deepEqual(ch.position, { tileX: 40, tileY: 41 }, '角色该落在发起者身边');
});

test('造角色：同场景其他人实时收到 character_spawned；发起者不重复收', async () => {
  const { store, conn } = rig();
  store.setFlowers('w1', 'pa', 9);
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'forest' });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'forest' });
  a.sent.length = 0;
  b.sent.length = 0;

  await a.say({ type: 'create_character_request', worldId: 'w1', playerId: 'pa', intentText: '一只小狗' });

  const spawned = b.ofType('character_spawned');
  assert.equal(spawned.length, 1, '同场景的 B 该实时看见新伙伴');
  assert.equal(spawned[0].sceneId, 'forest');
  assert.equal(spawned[0].character.id, a.ofType('gen_complete')[0].character.id);
  assert.equal(a.ofType('character_spawned').length, 0, '发起者已有 gen_complete，不该重复降生');
});

test('造角色：隔壁场景的人收不到 character_spawned', async () => {
  const { store, conn } = rig();
  store.setFlowers('w1', 'pa', 9);
  const a = conn('cA');
  const c = conn('cC');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'forest' });
  await c.say({ type: 'world_info', worldId: 'w1', playerId: 'pc', sceneId: DEFAULT_SCENE });
  c.sent.length = 0;

  await a.say({ type: 'create_character_request', worldId: 'w1', playerId: 'pa', intentText: '一只小鸟' });

  assert.equal(c.ofType('character_spawned').length, 0, 'village 的 C 看不见森林里降生的角色');
});
