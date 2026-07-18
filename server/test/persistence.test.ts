import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync, existsSync, mkdtempSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { WorldStore } from '../src/persistence.ts';
import { ANON_PLAYER, INITIAL_FLOWERS, type Character } from '../src/types.ts';

function char(worldId: string, id: string, name: string): Character {
  return {
    id, worldId, isFairy: false, name, personality: 'p', voiceId: 'v',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle',
    behaviorScript: { commands: [], loop: false },
    position: { tileX: 1, tileY: 2 }, abilities: ['move_to'], relationships: {},
  };
}

test('持久化：存盘→新实例读回，世界/角色/资源一致', () => {
  const dir = join(tmpdir(), 'maliang-test-persist');
  rmSync(dir, { recursive: true, force: true });

  // 写入
  const s1 = new WorldStore(dir);
  s1.createWorld('w1');
  const c = char('w1', 'c1', '小兔');
  const hash = s1.putAsset({ bytes: new Uint8Array([1, 2, 3, 4]), mime: 'image/png' });
  c.appearance.spriteAsset = hash;
  s1.addCharacter(c);

  assert.ok(existsSync(join(dir, 'world.db')), 'world.db 应落盘');
  assert.ok(existsSync(join(dir, 'assets', hash)), 'asset 文件应落盘');

  // 新实例从磁盘读回
  const s2 = new WorldStore(dir);
  const reloaded = s2.getCharacter('w1', 'c1');
  assert.ok(reloaded, '角色应被读回');
  assert.equal(reloaded!.name, '小兔');
  assert.equal(reloaded!.position.tileX, 1);
  const asset = s2.getAsset(hash);
  assert.ok(asset, '资源应被读回');
  assert.deepEqual([...asset!.bytes], [1, 2, 3, 4]);
  assert.equal(asset!.mime, 'image/png');

  rmSync(dir, { recursive: true, force: true });
});

test('内存模式（无 dataDir）：不落盘', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  s.addCharacter(char('w1', 'c1', '小猫'));
  assert.equal(s.listCharacters('w1').length, 1);
  // 无目录 → 不应创建 ./data（由其他测试隔离保证；此处仅验证 API 正常）
});

test('迁移：旧 worlds.json → SQLite 全字段等价，备份为 .migrated，二次实例不重复迁移', () => {
  const dir = mkdtempSync(join(tmpdir(), 'maliang-migrate-'));
  const oldChar = char('w1', 'c1', '小狐');
  oldChar.memory = ['小朋友叫朵朵', '小朋友喜欢恐龙'];
  oldChar.chatHistory = [
    { role: 'child', text: '你好呀', ts: 0 },
    { role: 'npc', text: '嗨，小朋友！', ts: 0 },
  ];
  // 旧格式 prop（spec 结构无关紧要，迁移是 JSON round-trip；只验证读回等价）
  const oldProp = { id: 'p1', spec: { shape: 'blob' }, tile: [3, 4], state: 'placed' };
  writeFileSync(
    join(dir, 'worlds.json'),
    JSON.stringify({ worlds: [{ id: 'w1', characters: [oldChar], inventory: { star: 2 }, activeTask: null, props: [oldProp] }] }),
  );

  const s = new WorldStore(dir);
  const c = s.getCharacter('w1', 'c1');
  assert.ok(c, '角色应迁移');
  assert.equal(c!.name, '小狐');
  assert.equal(c!.position.tileX, 1, '角色标量字段应迁移');
  // 旧 chatHistory[] 被 P5 legacy 迁移搬进 chat_turns 表并清空（player_id='' 未绑定历史）
  assert.deepEqual(c!.chatHistory, [], '旧 chatHistory[] 迁移后应清空');
  assert.deepEqual(
    s.getRecentTurns('c1', '', 10).map((t) => t.text),
    ['你好呀', '嗨，小朋友！'],
    'chatHistory 应搬进 chat_turns 表',
  );
  // 旧 memory[] 被 P3 legacy 迁移搬进 memories 表并清空（aboutPlayer='' 未绑定历史）
  assert.deepEqual(c!.memory, [], '旧 memory[] 迁移后应清空');
  assert.deepEqual(
    s.getMemories('c1', '').map((m) => m.text),
    ['小朋友叫朵朵', '小朋友喜欢恐龙'],
    'memory[] 应搬进 memories 表',
  );
  // 钱包 / 物件迁移：方案 A 清空旧贴纸背包，置初始小红花
  assert.deepEqual(s.getWallet('w1', ANON_PLAYER), { flowers: INITIAL_FLOWERS, stampProgress: 0, stampsTotal: 0, hearts: 0 });
  // 存量物件迁移：props 行 → items 实体行（sdf_inline）+ 匿名背包（w1 无场景矩阵，placed 也收背包）
  const migrated = s.listWorldItems('w1');
  assert.equal(migrated.length, 1, 'props 行应迁成 items 实体行');
  assert.equal(migrated[0].id, 'p1');
  assert.equal(migrated[0].renderRef, 'sdf_inline');
  assert.deepEqual(s.getBag('w1', ANON_PLAYER), { p1: 1 }, '无矩阵可落位 → 收进匿名背包');
  // 旧文件改名备份，不再存在
  assert.ok(!existsSync(join(dir, 'worlds.json')), '旧 worlds.json 应已改名');
  assert.ok(existsSync(join(dir, 'worlds.json.migrated')), '应留 .migrated 备份');

  // 二次实例：库非空 → 不重复迁移（记忆不翻倍，验证 legacy 迁移幂等）
  const s2 = new WorldStore(dir);
  assert.equal(s2.getMemories('c1', '').length, 2, '二次实例不重复迁移记忆');
  assert.equal(s2.getRecentTurns('c1', '', 10).length, 2, '二次实例不重复迁移对话');
  assert.deepEqual(s2.getBag('w1', ANON_PLAYER), { p1: 1 }, 'props 迁移幂等：背包不翻倍');

  rmSync(dir, { recursive: true, force: true });
});

test('记忆表：addMemory/getMemories 按 (NPC,玩家) 维度隔离，未绑定历史并入取', () => {
  const s = new WorldStore();
  s.addMemory('npc1', { text: '朵朵喜欢恐龙', kind: 'preference', aboutPlayer: 'p1', ts: 0 });
  s.addMemory('npc1', { text: '小明怕黑', kind: 'preference', aboutPlayer: 'p2', ts: 0 });
  s.addMemory('npc1', { text: '大家一起玩过', kind: 'event', aboutPlayer: '', ts: 0 }); // 未绑定历史
  s.addMemory('npc2', { text: '别的NPC记忆', kind: 'event', aboutPlayer: 'p1', ts: 0 });

  // p1 视角：p1 的 + 未绑定历史；不含 p2 的、不含别的 NPC 的
  assert.deepEqual(s.getMemories('npc1', 'p1').map((m) => m.text), ['朵朵喜欢恐龙', '大家一起玩过']);
  // p2 视角：p2 的 + 未绑定历史
  assert.deepEqual(s.getMemories('npc1', 'p2').map((m) => m.text), ['小明怕黑', '大家一起玩过']);
  // 结构字段回读
  const first = s.getMemories('npc1', 'p1')[0];
  assert.equal(first.kind, 'preference');
  assert.equal(first.aboutPlayer, 'p1');
});

test('对话表 chat_turns：addChatTurn/getRecentTurns 按 (NPC,玩家) 隔离 + 未绑定历史并入 + 正序', () => {
  const s = new WorldStore();
  s.addChatTurn('c1', '', 'child', '旧历史一', 0); // 未绑定玩家的历史
  s.addChatTurn('c1', 'p1', 'child', '朵朵说', 0);
  s.addChatTurn('c1', 'p1', 'npc', '你好朵朵', 0);
  s.addChatTurn('c1', 'p2', 'child', '小明说', 0); // 别的玩家
  // p1 视角：未绑定历史 + p1 的；不含 p2 的；按时间正序（最旧在前）
  assert.deepEqual(s.getRecentTurns('c1', 'p1', 10).map((t) => t.text), ['旧历史一', '朵朵说', '你好朵朵']);
  // p2 视角：未绑定历史 + p2 的
  assert.deepEqual(s.getRecentTurns('c1', 'p2', 10).map((t) => t.text), ['旧历史一', '小明说']);
  // limit 取最近 N 条（仍正序）
  assert.deepEqual(s.getRecentTurns('c1', 'p1', 2).map((t) => t.text), ['朵朵说', '你好朵朵']);
});

test('对话表 chat_turns：超 CAP 裁剪最旧（按 NPC×玩家，不无限膨胀）', () => {
  const s = new WorldStore();
  const cap = WorldStore.CHAT_TURN_CAP;
  for (let i = 0; i < cap + 5; i++) s.addChatTurn('c1', 'p1', 'child', `第${i}句`, 0);
  const all = s.getRecentTurns('c1', 'p1', cap + 100);
  assert.equal(all.length, cap, `应裁剪到 CAP=${cap}`);
  assert.equal(all[0]!.text, `第5句`, '最旧 5 句应被挤出');
  assert.equal(all[all.length - 1]!.text, `第${cap + 4}句`, '最新一句应保留');
});

test('会话表 Visit：startVisit/endVisit/listVisits（倒序、未收尾为 null、已收尾不覆盖）', () => {
  const s = new WorldStore();
  s.createWorld('w1');
  const id1 = s.startVisit('w1', 'p1', 1000);
  const id2 = s.startVisit('w1', 'p2', 2000);
  assert.notEqual(id1, id2, '每段 Visit 应有独立 id');
  const list = s.listVisits('w1');
  assert.equal(list.length, 2);
  assert.equal(list[0]!.startedAt, 2000, '按开始时间倒序');
  assert.equal(list[0]!.endedAt, null, '进行中 ended_at 为 null');
  s.endVisit(id1, 1500);
  assert.equal(s.listVisits('w1').find((v) => v.id === id1)!.endedAt, 1500, '收尾应落 ended_at');
  s.endVisit(id1, 9999); // 已收尾不应被覆盖
  assert.equal(s.listVisits('w1').find((v) => v.id === id1)!.endedAt, 1500, '已收尾的 Visit 不被二次覆盖');
});
