import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer, handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { FOREST_CHARACTER_SEEDS, FOREST_SCENE, seedForestCharacters } from '../src/forest_characters.ts';
import { GREETING_STYLES } from '../src/greetings.ts';
import { isKnownVoice } from '../src/voice_catalog.ts';
import { isValidTile, type Character } from '../src/types.ts';

function fakeSocket(): { send: (d: string) => void; sent: Array<Record<string, unknown>> } {
  const sent: Array<Record<string, unknown>> = [];
  return { send: (d: string) => sent.push(JSON.parse(d)), sent };
}

test('种子定义静态校验：音色在目录、招呼风格合法、落位合法且不压 portal 出口', () => {
  assert.ok(FOREST_CHARACTER_SEEDS.length >= 3 && FOREST_CHARACTER_SEEDS.length <= 4);
  const names = new Set(FOREST_CHARACTER_SEEDS.map((s) => s.name));
  assert.equal(names.size, FOREST_CHARACTER_SEEDS.length, '名字不重复（幂等键）');
  for (const s of FOREST_CHARACTER_SEEDS) {
    assert.ok(isKnownVoice(s.voiceId), `${s.name} 音色 ${s.voiceId} 应在目录里`);
    assert.ok(s.greetingStyle in GREETING_STYLES, `${s.name} 招呼风格合法`);
    assert.ok(isValidTile(s.position), `${s.name} 落位在界内`);
    assert.ok(
      !(s.position.tileX === 20 && s.position.tileY === 18),
      `${s.name} 不压 portal 出口 (20,18)`,
    );
    assert.ok(s.visualDescription.length > 0 && s.personality.length > 0);
  }
});

test('seedForestCharacters：全部种入 sceneId=forest + 幂等重跑跳过 + only 限定', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  store.createWorld('w1');

  const r1 = await seedForestCharacters(adapters, store, 'w1');
  assert.equal(r1.created.length, FOREST_CHARACTER_SEEDS.length);
  assert.equal(r1.skipped.length, 0);
  assert.equal(r1.failed.length, 0);

  const forest = store.listCharacters('w1', FOREST_SCENE);
  assert.equal(forest.length, FOREST_CHARACTER_SEEDS.length);
  for (const c of forest) {
    assert.equal(c.sceneId, FOREST_SCENE);
    assert.ok(c.appearance.spriteAsset.length > 0, `${c.name} 立绘已入库`);
    assert.ok(store.getSpriteAnim(c.appearance.spriteAsset) !== undefined, `${c.name} idle 动画已触发`);
    assert.equal(c.isFairy, false);
    assert.ok(c.abilities.length > 0);
  }
  // village 不被污染
  assert.equal(store.listCharacters('w1', 'village').length, 0);

  // 幂等：重跑全部跳过，不种双胞胎
  const r2 = await seedForestCharacters(adapters, store, 'w1');
  assert.equal(r2.created.length, 0);
  assert.equal(r2.skipped.length, FOREST_CHARACTER_SEEDS.length);
  assert.equal(store.listCharacters('w1', FOREST_SCENE).length, FOREST_CHARACTER_SEEDS.length);

  // only：另一个世界只种一个
  store.createWorld('w2');
  const one = FOREST_CHARACTER_SEEDS[0].name;
  const r3 = await seedForestCharacters(adapters, store, 'w2', { only: [one] });
  assert.deepEqual(r3.created.map((c) => c.name), [one]);
  assert.equal(store.listCharacters('w2', FOREST_SCENE).length, 1);
});

test('mock 全链路：admin 端点种入 → WS enter_scene 回森林村民 + 仙女', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const app = await buildServer({ adapters, store });
  try {
    // default 世界是 GET /worlds/default 懒创建的（顺带种 seedFairy）——先走一遍真实链路
    await app.inject({ method: 'GET', url: '/worlds/default' });
    assert.ok(store.getWorld('default'));

    // 无 token → 403；坏 token → 403
    assert.equal((await app.inject({ method: 'POST', url: '/admin/worlds/default/seed-forest' })).statusCode, 403);
    assert.equal(
      (await app.inject({ method: 'POST', url: '/admin/worlds/default/seed-forest', headers: { 'x-admin-token': 'nope' } })).statusCode,
      403,
    );
    // 不存在的世界 → 404
    assert.equal(
      (await app.inject({ method: 'POST', url: '/admin/worlds/no-such/seed-forest', headers: { 'x-admin-token': 'sesame' } })).statusCode,
      404,
    );

    const res = await app.inject({
      method: 'POST',
      url: '/admin/worlds/default/seed-forest',
      headers: { 'x-admin-token': 'sesame' },
    });
    assert.equal(res.statusCode, 200);
    const body = res.json() as { created: { name: string }[]; skipped: string[] };
    assert.equal(body.created.length, FOREST_CHARACTER_SEEDS.length);

    // 全链路验收：enter_scene forest 回包 = 森林村民 + 仙女（P1 恒带），村庄角色不串
    const sock = fakeSocket();
    const session = newVoiceSession();
    await handleWsMessage(
      sock,
      JSON.stringify({ type: 'enter_scene', worldId: 'default', sceneId: FOREST_SCENE }),
      adapters,
      store,
      new RateLimiter(100, 100),
      'test',
      session,
    );
    const m = sock.sent.find((x) => x.type === 'scene_entered');
    assert.ok(m, '应回 scene_entered');
    const chars = (m!.characters as Character[]) ?? [];
    const names = chars.map((c) => c.name).sort();
    const expected = [...FOREST_CHARACTER_SEEDS.map((s) => s.name)].sort();
    const fairies = chars.filter((c) => c.isFairy);
    assert.equal(fairies.length, 1, '仙女恒随场景下发');
    assert.deepEqual(
      names.filter((n) => !fairies.some((f) => f.name === n)).sort(),
      expected,
      '森林村民全员在场',
    );
  } finally {
    await app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
  }
});
