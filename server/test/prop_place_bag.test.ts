import { ANON_PLAYER } from '../src/types.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildServer, createPropAsync, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

async function ws(store: WorldStore, msg: Record<string, unknown>): Promise<Array<Record<string, unknown>>> {
  const sock = fakeSocket();
  await handleWsMessage(
    sock, JSON.stringify(msg),
    createMockAdapters(), store, new RateLimiter(100, 100), 'test', newVoiceSession(),
  );
  return sock.sent;
}

/** 建好 default 世界 + 一个已落位的语音物件，返回 propId。 */
async function seededProp(store: WorldStore): Promise<{ propId: string; close: () => Promise<void> }> {
  const adapters = createMockAdapters();
  const app = await buildServer({ adapters, store });
  await app.inject({ method: 'GET', url: '/worlds/default' });
  const sock = fakeSocket();
  await createPropAsync(sock, 'default', ANON_PLAYER, '造一个小风车', adapters, store);
  const propId = (sock.sent[0].prop as { id: string }).id;
  await ws(store, { type: 'prop_place', worldId: 'default', propId, tileX: 12, tileY: 34 });
  return { propId, close: () => app.close() };
}

// 新造物件默认 state=placed；prop_store 收纳 → bagged 且 tile 清空
test('prop_store: 已摆物件收进背包', async () => {
  const store = new WorldStore();
  const { propId, close } = await seededProp(store);
  try {
    assert.equal(store.listProps('default')[0].state, 'placed');

    const sent = await ws(store, { type: 'prop_store', worldId: 'default', propId });
    assert.equal(sent.length, 0); // 成功无回包（与 prop_place 一致）
    const prop = store.listProps('default')[0];
    assert.equal(prop.state, 'bagged');
    assert.equal(prop.tile, null);

    // 已在背包里再收一次 → error
    const again = await ws(store, { type: 'prop_store', worldId: 'default', propId });
    assert.equal(again[0].type, 'error');
    // 未知 propId → error
    const nope = await ws(store, { type: 'prop_store', worldId: 'default', propId: 'nope' });
    assert.equal(nope[0].type, 'error');
  } finally {
    await close();
  }
});

// prop_take：背包物件摆回世界 → placed + tile 更新；对 placed 物件 take → error
test('prop_take: 背包物件摆回世界', async () => {
  const store = new WorldStore();
  const { propId, close } = await seededProp(store);
  try {
    // placed 状态直接 take → error（必须先收进背包）
    const bad = await ws(store, { type: 'prop_take', worldId: 'default', propId, tileX: 5, tileY: 6 });
    assert.equal(bad[0].type, 'error');

    await ws(store, { type: 'prop_store', worldId: 'default', propId });
    const sent = await ws(store, { type: 'prop_take', worldId: 'default', propId, tileX: 5, tileY: 6 });
    assert.equal(sent.length, 0);
    const prop = store.listProps('default')[0];
    assert.equal(prop.state, 'placed');
    assert.deepEqual(prop.tile, [5, 6]);
  } finally {
    await close();
  }
});

// prop_move：已摆物件换位置；bagged 物件 move → error
test('prop_move: 已摆物件换位置', async () => {
  const store = new WorldStore();
  const { propId, close } = await seededProp(store);
  try {
    const sent = await ws(store, { type: 'prop_move', worldId: 'default', propId, tileX: 20, tileY: 21 });
    assert.equal(sent.length, 0);
    assert.deepEqual(store.listProps('default')[0].tile, [20, 21]);
    assert.equal(store.listProps('default')[0].state, 'placed');

    await ws(store, { type: 'prop_store', worldId: 'default', propId });
    const bad = await ws(store, { type: 'prop_move', worldId: 'default', propId, tileX: 1, tileY: 1 });
    assert.equal(bad[0].type, 'error');
  } finally {
    await close();
  }
});

// 磁盘 roundtrip：bagged 状态重开 store 后仍在背包；旧存档缺 state 字段 → 默认 placed
test('state 持久化 roundtrip + 旧存档兼容', async () => {
  const dir = join(tmpdir(), 'maliang-test-prop-bag');
  rmSync(dir, { recursive: true, force: true });
  const store = new WorldStore(dir);
  const { propId, close } = await seededProp(store);
  try {
    await ws(store, { type: 'prop_store', worldId: 'default', propId });

    const store2 = new WorldStore(dir);
    const prop = store2.listProps('default')[0];
    assert.equal(prop.state, 'bagged');
    assert.equal(prop.tile, null);
  } finally {
    await close();
    rmSync(dir, { recursive: true, force: true });
  }

  // 旧存档：props 无 state 字段 → load 后视为 placed
  const legacyDir = join(tmpdir(), 'maliang-test-prop-legacy');
  rmSync(legacyDir, { recursive: true, force: true });
  mkdirSync(legacyDir, { recursive: true });
  writeFileSync(join(legacyDir, 'worlds.json'), JSON.stringify({
    worlds: [{
      id: 'default',
      characters: [],
      props: [{ id: 'p-legacy', spec: { name: 'x', palette: ['#fff'], blend: 0.2, outline: 0.04, parts: [], locomotion: { type: 'none' }, ropes: [] }, tile: [3, 4] }],
    }],
  }));
  try {
    const legacy = new WorldStore(legacyDir);
    assert.equal(legacy.listProps('default')[0].state, 'placed');
  } finally {
    rmSync(legacyDir, { recursive: true, force: true });
  }
});
