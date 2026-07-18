// M2 章回剧情：故事角色种入（docs/m2-story-director-design.md §4.1/§5）。
// 照 seedForestCharacters 先例：立绘走 generateSprite 服务端管线在 seed 当刻生成——
// prod 实际单世界、seed 只跑一次（admin 端点触发），成本与形象确定性都可控；
// 本地/回测用 mock adapters，零网络。幂等：按 storyCharacterId 查重，已在 roster 就跳过。
//
// 种入即带 storyRole{resident:false}：未入住不进任何供给面（P2 的早返回），
// gate 角色（猪大哥）可搭话触发开演；整册完结 P4 翻 resident。

import type { LLMAdapter, ServiceAdapters } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { generateSprite } from './orchestrator.ts';
import { triggerCharacterAnimation, type ToSpriteSheet } from './idle_animation.ts';
import { ensureTaskChain } from './task_chain.ts';
import { BASE_ABILITIES, type Character } from './types.ts';
import { storyCharacterId, type StoryBook } from './story_books.ts';

export interface SeedStoryResult {
  created: { id: string; name: string; spriteAsset: string }[];
  skipped: string[];
  failed: string[];
}

/** 把一册的全部故事角色种进世界（含狼——舞台按 id 渲染，演员必须真实在 roster）。 */
export async function seedStoryCharacters(
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  book: StoryBook,
  opts: { toSpriteSheet?: ToSpriteSheet } = {},
): Promise<SeedStoryResult> {
  const result: SeedStoryResult = { created: [], skipped: [], failed: [] };
  for (const seed of book.cast) {
    const id = storyCharacterId(book.id, seed.castId);
    if (store.getCharacter(worldId, id)) {
      result.skipped.push(seed.name);
      continue;
    }
    try {
      const { hash: assetHash, anchors } = await generateSprite(adapters, seed.visualDescription, store);
      const character: Character = {
        id,
        worldId,
        isFairy: false,
        name: seed.name,
        personality: seed.personality,
        voiceId: seed.voiceId,
        greetingStyle: seed.greetingStyle,
        appearance: {
          visualDescription: seed.visualDescription,
          spriteAsset: assetHash,
          scale: 1.0,
          ...(anchors ? { anchors } : {}),
        },
        memory: [],
        chatHistory: [],
        state: 'idle',
        // 小范围踱步保有生气；狼站位本就远离村心，不给 wander 半径放大它的活动圈。
        behaviorScript: seed.noResidence
          ? { commands: [], loop: false }
          : { commands: [{ type: 'wander', params: { radius: 3, duration: 8 } }], loop: true },
        position: seed.position,
        sceneId: book.sceneId,
        abilities: [...BASE_ABILITIES],
        relationships: {},
        storyRole: { bookId: book.id, castId: seed.castId, resident: false },
      };
      store.addCharacter(character);
      triggerCharacterAnimation(adapters, store, assetHash, opts.toSpriteSheet);
      result.created.push({ id, name: seed.name, spriteAsset: assetHash });
    } catch (err) {
      console.warn(`故事角色种入失败（${seed.name}，跳过）：${String(err)}`);
      result.failed.push(seed.name);
    }
  }
  return result;
}

/**
 * 整册完结入住（M2 §4.5）：cast 里 noResidence 之外的故事角色翻 resident=true——从此各供给面
 * （心愿/漏话/委托/社交）放行，并照 createCharacterAsync 先例 fire-and-forget 生成专属委托链
 * （LLM 按小猪人设出链，失败回退模板链；「小猪住进村里带着盖房系列委托」即 M1 链的复用）。
 * 幂等：已 resident 的跳过（settled 门闩在 StoryDirector，这里是纵深）。返回翻转的角色 id。
 */
export function settleStoryResidency(worldId: string, book: StoryBook, store: WorldStore, llm: LLMAdapter): string[] {
  const moved: string[] = [];
  for (const seed of book.cast) {
    if (seed.noResidence) continue;
    const char = store.getCharacter(worldId, storyCharacterId(book.id, seed.castId));
    if (!char?.storyRole || char.storyRole.resident) continue;
    char.storyRole = { ...char.storyRole, resident: true };
    store.saveCharacter(char);
    ensureTaskChain(worldId, char.id, llm, store).catch((err) =>
      console.warn(`入住委托链生成失败（${char.id}，模板兜底也失败）：${String(err)}`),
    );
    moved.push(char.id);
  }
  return moved;
}
