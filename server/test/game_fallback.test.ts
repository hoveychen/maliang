// startGameAsync 兜底顺序（realtime-primitives P5 收尾）：
// 先判「能不能开」再应下——已在演出/并发满时不先说「好呀我们来玩」又反悔；能开才应下 leadIn 再开演。

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { startGameAsync, newVoiceSession } from '../src/server.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { WorldHub } from '../src/world_hub.ts';
import type { StageDirector } from '../src/stage_session.ts';
import { DEFAULT_SCENE, WORLD_CENTER_TILE, type Character } from '../src/types.ts';

function seedFairy(store: WorldStore): void {
  const c: Character = {
    id: 'f1', worldId: 'w1', isFairy: true, name: '小仙子', personality: 'p', voiceId: 'v-fairy',
    appearance: { visualDescription: '', spriteAsset: '', scale: 1 },
    memory: [], chatHistory: [], state: 'idle', behaviorScript: { commands: [], loop: false },
    position: WORLD_CENTER_TILE, sceneId: DEFAULT_SCENE, abilities: ['play_game'], relationships: {},
  };
  store.addCharacter(c);
}

function setup() {
  const store = new WorldStore();
  store.createWorld('w1');
  seedFairy(store);
  const hub = new WorldHub();
  hub.join('w1', { clientId: 'c1', playerId: 'p1', sceneId: DEFAULT_SCENE, send: () => {}, sendText: () => {}, posBin: false, sendBin: () => {} });
  const sent: Array<Record<string, unknown>> = [];
  const socket = { send: (d: string) => sent.push(JSON.parse(d)) };
  const session = newVoiceSession();
  session.clientTts = true; // 走文本路径，pushLineTts 不合成 TTS，确定性
  session.playerId = 'p1';
  session.currentScene = DEFAULT_SCENE;
  return { store, hub, sent, socket, session };
}

/** 从 sent 里取所有仙子口头句（praise_tts.text）。 */
function spokenLines(sent: Array<Record<string, unknown>>): string[] {
  return sent.filter((m) => m.type === 'praise_tts').map((m) => String(m.text ?? ''));
}

test('已在演出：只说兜底句，不先应下「好呀我们来玩」，也不调生成', async () => {
  const { store, hub, sent, socket, session } = setup();
  let genCalled = false;
  const adapters = createMockAdapters();
  adapters.llm.generateScreenplay = async () => { genCalled = true; return null; };
  const stages = { activeIn: () => true, atCapacity: () => false, startStage: () => null } as unknown as StageDirector;

  await startGameAsync(socket, session, 'w1', 'f1', '踢球', '好呀，我们来玩！', adapters, store, hub, stages);

  const lines = spokenLines(sent);
  assert.equal(lines.length, 1, '只说一句');
  assert.match(lines[0], /正在玩/);
  assert.equal(lines.some((l) => l.includes('好呀')), false, '不先应下应答句');
  assert.equal(genCalled, false, '已在演出不该调生成');
});

test('并发满：只说「稍等」兜底句，不应下、不生成', async () => {
  const { store, hub, sent, socket, session } = setup();
  let genCalled = false;
  const adapters = createMockAdapters();
  adapters.llm.generateScreenplay = async () => { genCalled = true; return null; };
  const stages = { activeIn: () => false, atCapacity: () => true, startStage: () => null } as unknown as StageDirector;

  await startGameAsync(socket, session, 'w1', 'f1', '踢球', '好呀，我们来玩！', adapters, store, hub, stages);

  const lines = spokenLines(sent);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /稍等|好多小朋友/);
  assert.equal(genCalled, false);
});

test('能开：先应下 leadIn，再用生成的剧本开演（startStage 收到 opts）', async () => {
  const { store, hub, sent, socket, session } = setup();
  const adapters = createMockAdapters(); // mock generateScreenplay 返回踢球剧本（cast=[]）
  let startedOpts: { code?: string } | null = null;
  const stages = {
    activeIn: () => false,
    atCapacity: () => false,
    startStage: (_w: string, opts: { code?: string }) => { startedOpts = opts; return Promise.resolve({ status: 'done' }); },
  } as unknown as StageDirector;

  await startGameAsync(socket, session, 'w1', 'f1', '踢球', '好呀，我们来玩！', adapters, store, hub, stages);

  const lines = spokenLines(sent);
  assert.equal(lines.some((l) => l.includes('好呀')), true, '能开时先应下 leadIn');
  assert.ok(startedOpts, 'startStage 被调用');
  assert.match(String((startedOpts as { code?: string }).code ?? ''), /spawnBall/, '开演的是生成的踢球剧本');
});

test('生成期间被别人抢先（startStage 返回 null）：先应下后落空说兜底句', async () => {
  const { store, hub, sent, socket, session } = setup();
  const adapters = createMockAdapters();
  const stages = { activeIn: () => false, atCapacity: () => false, startStage: () => null } as unknown as StageDirector;

  await startGameAsync(socket, session, 'w1', 'f1', '踢球', '好呀，我们来玩！', adapters, store, hub, stages);

  const lines = spokenLines(sent);
  assert.equal(lines.some((l) => l.includes('好呀')), true, '先应下了');
  assert.equal(lines.some((l) => l.includes('正在玩')), true, '被抢先后说兜底句');
});

test('世界不存在：说一句温柔话，不炸、不生成', async () => {
  const { hub, sent, socket, session } = setup();
  const store = new WorldStore(); // 空库，没有 w1
  const adapters = createMockAdapters();
  const stages = { activeIn: () => false, atCapacity: () => false, startStage: () => null } as unknown as StageDirector;

  await startGameAsync(socket, session, 'w1', 'f1', '踢球', '好呀，我们来玩！', adapters, store, hub, stages);

  const lines = spokenLines(sent);
  assert.equal(lines.length, 1);
  assert.match(lines[0], /世界|待会儿/);
});
