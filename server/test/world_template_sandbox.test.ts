// 世界模板架构 v2 P4（docs/world-template-instancing-design.md §5）：测试沙箱 admin 建/删。
// POST /admin/worlds/sandbox 从 template 复制放置成全新临时世界；作者「开沙箱→跑整册→丢掉」验隔离，
// 零污染 template。删走既有 admin DELETE（级联）。这里在服务端权威层证「隔离」：沙箱里入住
// 只翻自己那份，template/另一沙箱不受牵连；改共享定义一次全沙箱都变（克隆引用共享 def）。
// P6：内容直接 seed 进 template（default 已退役），沙箱从 template 克隆，源世界即 template。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildServer } from '../src/server.ts';
import { WorldStore, TEMPLATE_WORLD_ID } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import type { Character } from '../src/types.ts';

const STORY_ID = 'story_three_pigs_pig_big';

function storyPig(worldId: string, over: Partial<Character> = {}): Character {
  return {
    id: STORY_ID, worldId, isFairy: false, name: '猪大哥', personality: '稳重', voiceId: 'v-pig',
    appearance: { visualDescription: '草帽猪', spriteAsset: 'hashPIG', scale: 1.2 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: { tileX: 29, tileY: 49 }, sceneId: 'village', abilities: ['start_story'], relationships: {},
    storyRole: { bookId: 'three_pigs', castId: 'pig_big', resident: false }, ...over,
  };
}

// backupAuthed 在 buildServer 时【捕获一次】debugToken（与按请求现读 token 的 inline guard 端点不同），
// 故起 server 前就得把 MALIANG_ADMIN_TOKEN 设好。freshServer 统一在建 server 前设 token、after 清掉。
async function freshServer(t: { after: (fn: () => unknown) => void }): Promise<{ app: Awaited<ReturnType<typeof buildServer>>; store: WorldStore }> {
  process.env.MALIANG_ADMIN_TOKEN = 'sesame';
  const store = new WorldStore();
  store.ensureTemplateWorld(); // P6：空建 template，内容直接 seed 进去
  store.saveCharacter(storyPig(TEMPLATE_WORLD_ID));
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => { app.close(); delete process.env.MALIANG_ADMIN_TOKEN; });
  return { app, store };
}

const TOK = { 'x-admin-token': 'sesame' };

test('P4 沙箱端点：未配置 token 时关闭（403）', async (t) => {
  delete process.env.MALIANG_ADMIN_TOKEN; // 建 server 前就无 token → backupAuthed 恒 false
  const store = new WorldStore();
  store.ensureTemplateWorld();
  const app = await buildServer({ adapters: createMockAdapters(), store });
  t.after(() => app.close());
  assert.equal((await app.inject({ method: 'POST', url: '/admin/worlds/sandbox' })).statusCode, 403);
});

test('P4 沙箱端点：token 门禁 + 从 template 克隆出全新沙箱（含 story 角色 + 点点）', async (t) => {
  const { app, store } = await freshServer(t);
  const url = '/admin/worlds/sandbox';

  // token 错 → 403
  assert.equal((await app.inject({ method: 'POST', url, headers: { 'x-admin-token': 'nope' } })).statusCode, 403);

  // token 对 → 200，返回全新沙箱 id + 世界内容
  const res = await app.inject({ method: 'POST', url, headers: TOK });
  assert.equal(res.statusCode, 200);
  const body = res.json() as { id: string; characters: Array<{ id: string; isFairy: boolean; name: string }> };
  assert.ok(body.id.startsWith('sandbox_'), 'id 以 sandbox_ 开头');
  assert.ok(store.worldExists(body.id), '沙箱世界真的建了');
  // 含 template（作者直接 seed）的 story 角色
  assert.ok(body.characters.some((c) => c.id === STORY_ID && c.name === '猪大哥'), '沙箱含克隆来的 story 角色');
  // 端点用 seedFairy 保证有点点
  assert.ok(body.characters.some((c) => c.isFairy), '沙箱有点点');
  // 沙箱是独立世界，不是 template 本身
  assert.notEqual(body.id, TEMPLATE_WORLD_ID);
});

test('P4 隔离：沙箱里入住只翻自己那份，default/template/另一沙箱都不受牵连', async (t) => {
  const { app, store } = await freshServer(t);
  const a = (await app.inject({ method: 'POST', url: '/admin/worlds/sandbox', headers: TOK })).json() as { id: string };
  const b = (await app.inject({ method: 'POST', url: '/admin/worlds/sandbox', headers: TOK })).json() as { id: string };
  assert.notEqual(a.id, b.id, '两次开沙箱是两个独立世界');

  // 沙箱 A 里让小猪入住（走 getCharacter→改→saveCharacter，即真实热路径）
  const pig = store.getCharacter(a.id, STORY_ID)!;
  pig.storyRole = { ...pig.storyRole!, resident: true };
  pig.position = { tileX: 5, tileY: 5 };
  store.saveCharacter(pig);

  assert.equal(store.getCharacter(a.id, STORY_ID)!.storyRole!.resident, true, 'A 沙箱入住');
  assert.equal(store.getCharacter(b.id, STORY_ID)!.storyRole!.resident, false, 'B 沙箱不受牵连');
  assert.equal(store.getCharacter(TEMPLATE_WORLD_ID, STORY_ID)!.storyRole!.resident, false, 'template（源）不受牵连（零污染）');
  assert.deepEqual(store.getCharacter(TEMPLATE_WORLD_ID, STORY_ID)!.position, { tileX: 29, tileY: 49 }, 'template 位置不动');
});

test('P4 共享定义：改一次 def → 沙箱里那份也变（克隆引用共享定义，非复制）', async (t) => {
  const { app, store } = await freshServer(t);
  const s = (await app.inject({ method: 'POST', url: '/admin/worlds/sandbox', headers: TOK })).json() as { id: string };
  const def = store.getCharacterDef(STORY_ID)!;
  store.upsertCharacterDef({ ...def, name: '猪二哥' });
  assert.equal(store.getCharacter(s.id, STORY_ID)!.name, '猪二哥', '沙箱随共享定义更新');
  assert.equal(store.getCharacter(TEMPLATE_WORLD_ID, STORY_ID)!.name, '猪二哥', 'template 也随同一份定义更新');
});

test('P4 建/删闭环：DELETE 沙箱级联清掉，template 完好', async (t) => {
  const { app, store } = await freshServer(t);
  const s = (await app.inject({ method: 'POST', url: '/admin/worlds/sandbox', headers: TOK })).json() as { id: string };
  assert.ok(store.worldExists(s.id));

  const del = await app.inject({ method: 'DELETE', url: `/admin/worlds/${s.id}`, headers: TOK });
  assert.equal(del.statusCode, 200);
  assert.equal(store.worldExists(s.id), false, '沙箱已删');
  // template 仍在，其 story 角色完好（沙箱删除不碰共享定义/别的世界）
  assert.ok(store.worldExists(TEMPLATE_WORLD_ID));
  assert.equal(store.getCharacter(TEMPLATE_WORLD_ID, STORY_ID)!.name, '猪大哥', 'template 角色完好');
  assert.ok(store.getCharacterDef(STORY_ID), '共享定义未被沙箱删除牵连');
});
