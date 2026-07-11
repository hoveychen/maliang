import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleWsMessage, newVoiceSession, type VoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { REQUIRED_GRID } from '../src/terrain.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character, type Player } from '../src/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function ws(store: WorldStore, msg: Record<string, unknown>, session: VoiceSession) {
  const sock = fakeSocket();
  await handleWsMessage(sock, JSON.stringify(msg), createMockAdapters(), store, new RateLimiter(100, 100), 'test', session);
  return sock.sent;
}

function char(worldId: string, id: string, sceneId: string): Character {
  return {
    id, worldId, isFairy: false, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId, abilities: [], relationships: {},
  };
}

function seed(): WorldStore {
  const s = new WorldStore();
  s.createWorld('w1');
  s.upsertScene({
    worldId: 'w1', sceneId: 'forest', name: '森林', terrainAsset: 'hash-forest', gridTiles: REQUIRED_GRID, terrainVersion: 1,
    pois: [{ tile: [2, 2], radius: 5, trigger: 't', name: '树屋', aliases: [] }],
    portals: [{ tile: [0, 0], radius: 3, toScene: DEFAULT_SCENE, toTile: [37, 37] }],
  });
  s.addCharacter(char('w1', 'v1', DEFAULT_SCENE));
  s.addCharacter(char('w1', 'f1', 'forest'));
  return s;
}

test('enter_scene：回该场景的 scene(地形hash/pois/portals) + 该场景角色，跨场景不串', async () => {
  const s = seed();
  const session = newVoiceSession();
  const sent = await ws(s, { type: 'enter_scene', worldId: 'w1', sceneId: 'forest' }, session);

  const m = sent[0];
  assert.equal(m.type, 'scene_entered');
  assert.equal(m.sceneId, 'forest');
  const scene = m.scene as { terrainAsset: string; name: string; pois: unknown[]; portals: unknown[] };
  assert.equal(scene.terrainAsset, 'hash-forest');
  assert.equal(scene.name, '森林');
  assert.equal(scene.pois.length, 1);
  assert.equal(scene.portals.length, 1);

  const chars = m.characters as { id: string }[];
  assert.deepEqual(chars.map((c) => c.id), ['f1'], '只下发 forest 的角色，village 的 v1 不串过来');
});

test('enter_scene：更新 session.currentScene', async () => {
  const s = seed();
  const session = newVoiceSession();
  assert.equal(session.currentScene, DEFAULT_SCENE, '初值 village');
  await ws(s, { type: 'enter_scene', worldId: 'w1', sceneId: 'forest' }, session);
  assert.equal(session.currentScene, 'forest');
});

test('enter_scene：场景没入库 → scene 为 null（客户端回退）', async () => {
  const s = seed();
  const sent = await ws(s, { type: 'enter_scene', worldId: 'w1', sceneId: 'desert' }, newVoiceSession());
  assert.equal(sent[0].scene, null);
  assert.deepEqual(sent[0].characters, []);
});

test('enter_scene：带 playerId 时回该场景玩家的最后位置', async () => {
  const s = seed();
  const p: Player = { id: 'A', name: 'n', nickname: '', gender: 'boy', color: '蓝', spriteAsset: '', createdAt: 'x' };
  s.upsertPlayer(p);
  s.setPlayerTile('w1', 'forest', 'A', { tileX: 8, tileY: 9 });
  s.setPlayerTile('w1', DEFAULT_SCENE, 'A', { tileX: 1, tileY: 1 });

  const session = newVoiceSession();
  session.playerId = 'A';
  const sent = await ws(s, { type: 'enter_scene', worldId: 'w1', sceneId: 'forest' }, session);
  assert.deepEqual(sent[0].playerPos, { tileX: 8, tileY: 9 }, '回 forest 的位置，不是 village 的');
});

test('enter_scene：无 playerId → playerPos undefined', async () => {
  const s = seed();
  const sent = await ws(s, { type: 'enter_scene', worldId: 'w1', sceneId: 'forest' }, newVoiceSession());
  assert.equal('playerPos' in sent[0] ? sent[0].playerPos : undefined, undefined);
});

test('world_info 置 session.currentScene 初值', async () => {
  const s = seed();
  const session = newVoiceSession();
  await ws(s, { type: 'world_info', worldId: 'w1', locations: [], sceneId: 'forest' }, session);
  assert.equal(session.currentScene, 'forest');
});
