import { randomUUID } from 'node:crypto';
import type { ServiceAdapters } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import type { Character, CharacterSpec, CreateCharacterInput, GenStage } from './types.ts';

/** 内容审核拦截。stage 指明在文字还是图片环节被拦。 */
export class ModerationError extends Error {
  readonly stage: 'text' | 'image';
  constructor(stage: 'text' | 'image', reason?: string) {
    super(`moderation blocked at ${stage}: ${reason ?? 'unspecified'}`);
    this.name = 'ModerationError';
    this.stage = stage;
  }
}

export type ProgressFn = (stage: GenStage) => void;

const DEFAULT_TILE = { tileX: 500, tileY: 500 };

function buildCharacter(
  spec: CharacterSpec,
  input: CreateCharacterInput,
  assetHash: string,
): Character {
  return {
    id: randomUUID(),
    worldId: input.worldId,
    isFairy: false,
    name: spec.name,
    personality: spec.personality,
    voiceId: spec.voiceId,
    appearance: { visualDescription: spec.visualDescription, spriteAsset: assetHash, scale: spec.scale },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [{ type: 'wander', params: { radius: 5, duration: 8 } }], loop: true },
    position: input.position ?? DEFAULT_TILE,
    abilities: spec.abilities,
    relationships: {},
  };
}

/**
 * 造角色编排管线（见 docs/tech-design.md §5.3）。
 * 顺序：spec → moderate_text → image → cutout → moderate_image → persist。
 * 每阶段开始时回调 onProgress；审核不通过抛 ModerationError。
 */
export async function createCharacter(
  input: CreateCharacterInput,
  adapters: ServiceAdapters,
  store: WorldStore,
  onProgress: ProgressFn = () => {},
): Promise<Character> {
  onProgress('spec');
  const spec = await adapters.llm.designCharacter(input.intentText, input.byFairy);

  onProgress('moderate_text');
  const textCheck = await adapters.moderation.moderateText(
    `${spec.name}。${spec.personality}。${spec.visualDescription}`,
  );
  if (!textCheck.allowed) throw new ModerationError('text', textCheck.reason);

  onProgress('image');
  const raw = await adapters.image.generateSprite(spec.visualDescription);

  onProgress('cutout');
  const cut = await adapters.cutout.removeBackground(raw);

  onProgress('moderate_image');
  const imageCheck = await adapters.moderation.moderateImage(cut);
  if (!imageCheck.allowed) throw new ModerationError('image', imageCheck.reason);

  onProgress('persist');
  const assetHash = store.putAsset(cut);
  const character = buildCharacter(spec, input, assetHash);
  store.addCharacter(character);
  return character;
}
