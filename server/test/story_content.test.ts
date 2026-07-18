// M2 P3（docs/m2-story-director-design.md §5）：首册《三只小猪》内容完整性——
// 册形状/剧本注册与 typecheck 门禁（typecheck 本体在 screenplay_typecheck.test.ts 随 SCREENPLAYS 自动覆盖）/
// 台词与预烧清单 lines.json 一一对应 / seed 幂等与 storyRole 标记。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WorldStore } from '../src/persistence.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { STORY_BOOKS, THREE_PIGS, storyCharacterId } from '../src/story_books.ts';
import { seedStoryCharacters } from '../src/story_seed.ts';
import { SCREENPLAYS, loadScreenplay } from '../src/screenplays.ts';
import { findBlueprint } from '../src/build_blueprints.ts';
import { isKnownVoice } from '../src/voice_catalog.ts';
import { STAMP_STYLES } from '../src/types.ts';

const here = dirname(fileURLToPath(import.meta.url));
const VOICE_DIR = join(here, '../../assets/voice/story_three_pigs');

interface VoiceLine { id: string; role: string; voice?: string; text: string }
const spec = JSON.parse(readFileSync(join(VOICE_DIR, 'lines.json'), 'utf8')) as { voice: string; lines: VoiceLine[] };

/** 从剧本源码里抠出全部要出声的台词（say 的第一个参数 + narrate 参数）。 */
function spokenLines(code: string): string[] {
  const out: string[] = [];
  for (const m of code.matchAll(/\.say\('([^']+)'/g)) out.push(m[1]!);
  for (const m of code.matchAll(/\bnarrate\('([^']+)'/g)) out.push(m[1]!);
  return out;
}

// ── 册形状 ───────────────────────────────────────────────────────────────

test('三只小猪已注册且形状自洽：gate 在 cast 里、互动引用的 castId 都存在', () => {
  assert.equal(STORY_BOOKS['three_pigs'], THREE_PIGS);
  const castIds = new Set(THREE_PIGS.cast.map((c) => c.castId));
  assert.ok(castIds.has(THREE_PIGS.gateCastId));
  for (const ch of THREE_PIGS.chapters) {
    if (!ch.interaction) continue;
    assert.ok(castIds.has(ch.interaction.npcCastId), `${ch.screenplay} 的委托人 castId 存在`);
    if (ch.interaction.kind === 'task' && ch.interaction.targetCastId) {
      assert.ok(castIds.has(ch.interaction.targetCastId));
    }
    assert.ok(ch.stampStyle && STAMP_STYLES.includes(ch.stampStyle), `${ch.screenplay} 盖章款式合法`);
  }
  // 尾声：无互动无盖章（演完直接完结入住）
  const last = THREE_PIGS.chapters[THREE_PIGS.chapters.length - 1]!;
  assert.equal(last.interaction, undefined);
});

test('build 互动的蓝图存在（B1 小房子）；cast 音色都在 edge 目录里', () => {
  for (const ch of THREE_PIGS.chapters) {
    if (ch.interaction?.kind === 'build') assert.ok(findBlueprint(ch.interaction.blueprintId), ch.interaction.blueprintId);
  }
  for (const c of THREE_PIGS.cast) assert.ok(isKnownVoice(c.voiceId), `${c.name} 音色 ${c.voiceId}`);
  // 狼是纯演出角色
  assert.equal(THREE_PIGS.cast.find((c) => c.castId === 'wolf')?.noResidence, true);
});

test('各幕剧本都注册进了 SCREENPLAYS（typecheck 门禁随注册自动覆盖）', () => {
  for (const ch of THREE_PIGS.chapters) {
    assert.ok((SCREENPLAYS as readonly string[]).includes(ch.screenplay), ch.screenplay);
  }
});

// ── 台词 ↔ 预烧清单互证 ─────────────────────────────────────────────────

test('剧本里每句 say/narrate 都在 lines.json 里，反之无孤儿行（预烧覆盖完整）', () => {
  const packTexts = new Set(spec.lines.map((l) => l.text));
  const played: string[] = [];
  for (const ch of THREE_PIGS.chapters) {
    for (const text of spokenLines(loadScreenplay(ch.screenplay as (typeof SCREENPLAYS)[number]))) {
      played.push(text);
      assert.ok(packTexts.has(text), `台词未预烧：「${text}」`);
    }
  }
  const playedSet = new Set(played);
  for (const l of spec.lines) {
    assert.ok(playedSet.has(l.text), `lines.json 孤儿行（剧本里没人说）：「${l.text}」`);
  }
});

test('lines.json：id 唯一且守 three_pigs_<幕>_<序> 约定，音色都在目录里', () => {
  const ids = new Set<string>();
  for (const l of spec.lines) {
    assert.ok(!ids.has(l.id), `重复 id ${l.id}`);
    ids.add(l.id);
    assert.match(l.id, /^three_pigs_[0-3]_\d+$/);
    assert.ok(isKnownVoice(l.voice ?? spec.voice), l.id);
  }
});

test('预烧 WAV 齐全：lines.json 每行都有同名 .wav（资产核数）', () => {
  for (const l of spec.lines) {
    assert.ok(existsSync(join(VOICE_DIR, `${l.id}.wav`)), `缺 WAV：${l.id}`);
  }
});

// ── seed ────────────────────────────────────────────────────────────────

test('seedStoryCharacters：4 角全落 roster 带 storyRole 未入住，幂等重跑全跳过', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const r1 = await seedStoryCharacters(adapters, store, 'w1', THREE_PIGS);
  assert.equal(r1.created.length, 4);
  assert.deepEqual(r1.failed, []);
  for (const c of THREE_PIGS.cast) {
    const char = store.getCharacter('w1', storyCharacterId('three_pigs', c.castId))!;
    assert.ok(char, c.name);
    assert.deepEqual(char.storyRole, { bookId: 'three_pigs', castId: c.castId, resident: false });
    assert.equal(char.sceneId, 'village');
    assert.ok(char.appearance.spriteAsset.length > 0, '立绘已入内容寻址库');
  }
  // 狼不踱步（站位远离村心，不放大活动圈）
  const wolf = store.getCharacter('w1', storyCharacterId('three_pigs', 'wolf'))!;
  assert.equal(wolf.behaviorScript.commands.length, 0);
  // 幂等
  const r2 = await seedStoryCharacters(adapters, store, 'w1', THREE_PIGS);
  assert.equal(r2.created.length, 0);
  assert.equal(r2.skipped.length, 4);
});
