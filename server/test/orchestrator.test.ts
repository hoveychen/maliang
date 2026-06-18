import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createCharacter, ModerationError } from '../src/orchestrator.ts';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { GEN_STAGES, type GenStage } from '../src/types.ts';

test('造角色闭环：按顺序推进度、产出角色、落地世界', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const stages: GenStage[] = [];

  const character = await createCharacter(
    { worldId: 'w1', intentText: '我想要一只会跳舞的小兔', byFairy: true },
    adapters,
    store,
    (s) => stages.push(s),
  );

  assert.equal(character.name, '小兔');
  assert.deepEqual(stages, [...GEN_STAGES]); // spec→moderate_text→image→cutout→moderate_image→persist
  assert.ok(character.appearance.spriteAsset.length > 0, 'sprite 资源已落地');
  assert.deepEqual(character.position, { tileX: 500, tileY: 500 });
  assert.equal(store.listCharacters('w1').length, 1);
});

test('文字审核拦截：抛 ModerationError(text) 且不落地', async () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const base = createMockAdapters();
  const adapters = {
    ...base,
    llm: {
      ...base.llm,
      async designCharacter() {
        return {
          name: '坏蛋',
          personality: '喜欢暴力和打架',
          visualDescription: 'x',
          voiceId: 'v',
          scale: 1,
          abilities: [],
        };
      },
    },
  };

  await assert.rejects(
    () => createCharacter({ worldId: 'w1', intentText: 'x', byFairy: true }, adapters, store),
    (e) => e instanceof ModerationError && e.stage === 'text',
  );
  assert.equal(store.listCharacters('w1').length, 0, '被拦截的角色不应落地');
});
