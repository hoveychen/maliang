import { randomUUID } from 'node:crypto';
import type { ImageBlob, ServiceAdapters } from './adapters/types.ts';
import { flipHorizontal } from './adapters/chroma_cutout.ts';
import type { WorldStore } from './persistence.ts';
import type { Character, CharacterSpec, CreateCharacterInput, GenStage } from './types.ts';

/** 内容审核拦截（文字环节）。 */
export class ModerationError extends Error {
  readonly stage: 'text';
  constructor(reason?: string) {
    super(`moderation blocked at text: ${reason ?? 'unspecified'}`);
    this.name = 'ModerationError';
    this.stage = 'text';
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

/** 生图 + 抠图（两条管线共用的前半段）。 */
async function generateCut(adapters: ServiceAdapters, visualDescription: string): Promise<ImageBlob> {
  const raw = await adapters.image.generateSprite(visualDescription);
  return adapters.cutout.removeBackground(raw);
}

/**
 * 朝向兜底：游戏端约定「原图=朝右」（world.gd 水平镜像做朝左），但生图模型对
 * prompt 里 "facing right" 的服从没有硬保证（线上曾出过整批朝左/正面的存量）。
 * 检测到朝左 → 水平翻转即合规；正面 → 翻转无意义（左右对称），重试一次生图，
 * 仍不合规就保守用第一张（正面只是螃蟹步，不至于倒走）；unknown（检测故障）放行。
 */
async function ensureFacingRight(
  adapters: ServiceAdapters,
  visualDescription: string,
  cut: ImageBlob,
): Promise<ImageBlob> {
  const facing = await adapters.orientation.detectFacing(cut);
  if (facing === 'left') return flipHorizontal(cut);
  if (facing !== 'front') return cut;
  let retry: ImageBlob;
  try {
    retry = await generateCut(adapters, visualDescription);
  } catch {
    return cut; // 重试失败不阻塞：第一张已过审，直接用
  }
  const facing2 = await adapters.orientation.detectFacing(retry);
  if (facing2 === 'left') return flipHorizontal(retry);
  if (facing2 === 'right') return retry;
  return cut;
}

/**
 * 为已存在角色（如小神仙）生成一张 sprite：image → cutout → 朝向兜底 → 存储，返回 assetHash。
 * 与 createCharacter 的造角色管线不同——这里不新建角色、不跑文字审核（描述是固定的）。
 */
export async function generateSprite(
  adapters: ServiceAdapters,
  visualDescription: string,
  store: WorldStore,
): Promise<string> {
  const cut = await generateCut(adapters, visualDescription);
  const upright = await ensureFacingRight(adapters, visualDescription, cut);
  return store.putAsset(upright);
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
  if (!textCheck.allowed) throw new ModerationError(textCheck.reason);

  onProgress('image');
  const raw = await adapters.image.generateSprite(spec.visualDescription);

  onProgress('cutout');
  const cut = await adapters.cutout.removeBackground(raw);
  // 朝向兜底归在 cutout 阶段内（不加新 GenStage，客户端进度文案零改动）
  const upright = await ensureFacingRight(adapters, spec.visualDescription, cut);

  // 图片不再单独审核：生图模型自带安全门（见 docs）。文字审核仍保留。
  onProgress('persist');
  const assetHash = store.putAsset(upright);
  const character = buildCharacter(spec, input, assetHash);
  store.addCharacter(character);
  return character;
}
