import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { inferSizeFromText } from '../src/creation_options.ts';
import { WORLD_CENTER_TILE, type Character } from '../src/types.ts';

// 存量角色体型回填：/admin/calibrate-size 从 visualDescription 推体型→写 appearance.scale。

function char(worldId: string, id: string, visual: string, scale = 1.0, isFairy = false): Character {
  return {
    id, worldId, isFairy, name: id, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: visual, spriteAsset: 's', scale },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId: 'village', abilities: [], relationships: {},
  };
}

test('inferSizeFromText 认英文体型词（存量 visualDescription 是英文）', () => {
  assert.equal(inferSizeFromText('a huge friendly dinosaur'), 'big');
  assert.equal(inferSizeFromText('a tiny little bunny'), 'small');
  assert.equal(inferSizeFromText('a giant fluffy bear'), 'big');
  assert.equal(inferSizeFromText('a small round cat'), 'small');
  assert.equal(inferSizeFromText('a friendly round animal friend'), 'medium'); // 无体型词
});

test('mock classifyCreatureSize 走中英正则', async () => {
  const { llm } = createMockAdapters();
  assert.equal(await llm.classifyCreatureSize('an enormous purple dragon'), 'big');
  assert.equal(await llm.classifyCreatureSize('a teeny yellow chick'), 'small');
  assert.equal(await llm.classifyCreatureSize('a normal green frog'), 'medium');
});

test('/admin/calibrate-size：token 门禁 + 推体型写 scale + 跳仙子 + 只改未标定', async () => {
  const store = new WorldStore();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  try {
    store.createWorld('w1');
    store.addCharacter(char('w1', 'bigone', 'a huge towering dinosaur', 1.0));
    store.addCharacter(char('w1', 'smallone', 'a tiny little mouse', 1.0));
    store.addCharacter(char('w1', 'plainone', 'a round friendly blob', 1.0));
    store.addCharacter(char('w1', 'fairy1', 'a huge sparkly fairy', 1.0, true)); // 仙子应跳过
    store.addCharacter(char('w1', 'done', 'a huge giant whale', 1.4)); // 已标定(1.4)应跳过

    const url = '/admin/calibrate-size?world=w1';

    // 门禁
    delete process.env.MALIANG_ADMIN_TOKEN;
    assert.equal((await app.inject({ method: 'POST', url })).statusCode, 403);

    process.env.MALIANG_ADMIN_TOKEN = 'sesame';
    assert.equal((await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'no' } })).statusCode, 403);

    const res = await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'sesame' } });
    assert.equal(res.statusCode, 200);

    // 大→1.4 / 小→0.7 / 无词→1.0；仙子和已标定的被跳过（scale 不变）
    assert.equal(store.getCharacter('w1', 'bigone')?.appearance.scale, 1.4);
    assert.equal(store.getCharacter('w1', 'smallone')?.appearance.scale, 0.7);
    assert.equal(store.getCharacter('w1', 'plainone')?.appearance.scale, 1.0);
    assert.equal(store.getCharacter('w1', 'fairy1')?.appearance.scale, 1.0, '仙子不动');
    assert.equal(store.getCharacter('w1', 'done')?.appearance.scale, 1.4, '已标定不覆盖');

    const body = res.json() as { calibrated: number; results: { id: string; skipped?: string }[] };
    assert.equal(body.calibrated, 3); // bigone/smallone/plainone
    assert.ok(body.results.find((r) => r.id === 'fairy1')?.skipped === 'fairy');
    assert.ok(body.results.find((r) => r.id === 'done')?.skipped === 'already calibrated');

    // ?force=1：连已标定的也重标（done 的 huge→仍 1.4，但不再 skip）
    const forced = await app.inject({ method: 'POST', url: '/admin/calibrate-size?world=w1&force=1', headers: { 'x-admin-token': 'sesame' } });
    const fbody = forced.json() as { results: { id: string; skipped?: string }[] };
    assert.equal(fbody.results.find((r) => r.id === 'done')?.skipped, undefined, 'force 下不跳过已标定');
  } finally {
    delete process.env.MALIANG_ADMIN_TOKEN;
    await app.close();
  }
});
