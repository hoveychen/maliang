// 玩家实体（P2）：players 表 CRUD/回读 + world_info 带 playerId+profile 首见建档 + 会话记住当前玩家。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync, mkdtempSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import type { Character, Player } from '../src/types.ts';

function player(id: string, over: Partial<Player> = {}): Player {
  return {
    id,
    name: '朵朵',
    nickname: '朵朵',
    gender: 'girl',
    color: '粉色',
    spriteAsset: 'abc123',
    createdAt: '2026-07-08T00:00:00Z',
    ...over,
  };
}

test('players CRUD：upsert→get 回读，同 id 再 upsert 覆盖，listPlayers 全量', () => {
  const s = new WorldStore();
  s.upsertPlayer(player('p1'));
  assert.deepEqual(s.getPlayer('p1'), player('p1'));
  // 同 id 更新（换昵称）
  s.upsertPlayer(player('p1', { nickname: '朵朵公主' }));
  assert.equal(s.getPlayer('p1')!.nickname, '朵朵公主');
  // 另一个玩家
  s.upsertPlayer(player('p2', { name: '小明', gender: 'boy' }));
  assert.equal(s.listPlayers().length, 2);
  assert.equal(s.getPlayer('missing'), undefined);
});

test('players 持久化：存盘→新实例读回一致', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-player-'));
  const s1 = new WorldStore(dir);
  s1.upsertPlayer(player('p1'));
  const s2 = new WorldStore(dir);
  assert.deepEqual(s2.getPlayer('p1'), player('p1'));
  rmSync(dir, { recursive: true, force: true });
});

function seedChar(store: WorldStore, worldId: string, id: string): Character {
  const c: Character = {
    id, worldId, isFairy: false, name: '小兔', personality: '活泼', voiceId: 'v1',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 0, tileY: 0 }, abilities: ['move_to'], relationships: {},
  };
  store.addCharacter(c);
  return c;
}

function setup() {
  const store = new WorldStore();
  store.createWorld('w1');
  seedChar(store, 'w1', 'c1');
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session] as const;
  return { sent, socket, session, store, rest };
}

test('world_info 带 playerId+profile → 首见建档 + 记进会话', async () => {
  const { socket, session, store, rest } = setup();
  await handleWsMessage(
    socket,
    JSON.stringify({
      type: 'world_info',
      worldId: 'w1',
      playerId: 'dev-uuid-1',
      profile: { name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉色', spriteAsset: 'h1', createdAt: '2026-07-08T00:00:00Z' },
      locations: ['风车'],
    }),
    ...rest,
  );
  const p = store.getPlayer('dev-uuid-1');
  assert.ok(p, '玩家应建档');
  assert.equal(p!.name, '朵朵');
  assert.equal(p!.spriteAsset, 'h1');
  assert.equal(session.playerId, 'dev-uuid-1', '会话应记住当前玩家');
});

test('world_info 无 profile 只带 playerId → 记进会话但不建空档', async () => {
  const { socket, session, store, rest } = setup();
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'world_info', worldId: 'w1', playerId: 'dev-uuid-2', locations: [] }),
    ...rest,
  );
  assert.equal(session.playerId, 'dev-uuid-2', '会话应记住当前玩家');
  assert.equal(store.getPlayer('dev-uuid-2'), undefined, '无 profile 不建档（避免写空档）');
});

test('任意消息带 playerId → 更新会话当前玩家', async () => {
  const { socket, session, rest } = setup();
  await handleWsMessage(
    socket,
    JSON.stringify({ type: 'voice_transcript', worldId: 'w1', characterId: 'c1', transcript: '你好', playerId: 'dev-uuid-3' }),
    ...rest,
  );
  assert.equal(session.playerId, 'dev-uuid-3');
});
