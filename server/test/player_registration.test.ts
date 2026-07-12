import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import type { Player } from '../src/types.ts';

function harness() {
  const store = new WorldStore();
  store.createWorld('w1');
  const sent: unknown[] = [];
  const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
  const session = newVoiceSession();
  const rest = [createMockAdapters(), store, new RateLimiter(100, 100), 'conn1', session] as const;
  return { store, socket, rest, sent };
}

// 复现「无立绘玩家」脏数据：客户端跳过/未建角色时仍会带 playerId + 全空字段的 profile
// 上报 world_info（upload_dict 返回 name/spriteAsset 全空的对象）。服务端不该据此建档。
test('world_info：全空 profile 不建玩家档（无立绘脏数据）', async () => {
  const { store, socket, rest } = harness();
  await handleWsMessage(
    socket,
    JSON.stringify({
      type: 'world_info',
      worldId: 'w1',
      playerId: 'p-empty',
      profile: { name: '', nickname: '', gender: '', color: '', spriteAsset: '', createdAt: '2026-07-10T00:00:00' },
    }),
    ...rest,
  );
  assert.equal(store.getPlayer('p-empty'), undefined, '全空 profile 不应创建玩家行');
  assert.equal(store.listPlayers().length, 0, 'players 表应为空');
});

// 正向对照：有真名字/立绘的 profile 正常建档（防误伤真实首见建档）。
test('world_info：有名字或立绘的 profile 正常建档', async () => {
  const { store, socket, rest } = harness();
  await handleWsMessage(
    socket,
    JSON.stringify({
      type: 'world_info',
      worldId: 'w1',
      playerId: 'p-real',
      profile: { name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉色', spriteAsset: 'deadbeef', createdAt: '2026-07-10T00:00:00' },
    }),
    ...rest,
  );
  const p = store.getPlayer('p-real');
  assert.ok(p, '有真档案应建玩家行');
  assert.equal(p?.name, '朵朵');
  assert.equal(p?.spriteAsset, 'deadbeef');
});

// 只有立绘、没名字也算真角色（造角色可能先出形象后补名）。
test('world_info：仅有立绘也建档', async () => {
  const { store, socket, rest } = harness();
  await handleWsMessage(
    socket,
    JSON.stringify({
      type: 'world_info',
      worldId: 'w1',
      playerId: 'p-sprite-only',
      profile: { name: '', nickname: '', gender: '', color: '', spriteAsset: 'cafe', createdAt: '' },
    }),
    ...rest,
  );
  assert.ok(store.getPlayer('p-sprite-only'), '有立绘应建玩家行');
});

// 空 profile 不得覆盖已有的真实档案（重连时客户端若档案丢失也不该抹掉服务端记录）。
test('world_info：全空 profile 不覆盖已有真实档', async () => {
  const { store, socket, rest } = harness();
  const real: Player = { id: 'p1', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉色', spriteAsset: 'deadbeef', createdAt: '2026-07-10T00:00:00' };
  store.upsertPlayer(real);
  await handleWsMessage(
    socket,
    JSON.stringify({
      type: 'world_info',
      worldId: 'w1',
      playerId: 'p1',
      profile: { name: '', nickname: '', gender: '', color: '', spriteAsset: '', createdAt: '' },
    }),
    ...rest,
  );
  const p = store.getPlayer('p1');
  assert.equal(p?.name, '朵朵', '已有真实档不应被空 profile 覆盖');
  assert.equal(p?.spriteAsset, 'deadbeef');
});
