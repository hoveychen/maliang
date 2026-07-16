import { randomUUID } from 'node:crypto';
import type { ServiceAdapters } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { generateSprite } from './orchestrator.ts';
import { triggerCharacterAnimation, type ToSpriteSheet } from './idle_animation.ts';
import { BASE_ABILITIES, type Character, type TilePos } from './types.ts';
import type { GreetingStyle } from './greetings.ts';

/** 森林场景 id（与 tools/export_forest.gd 导出、/admin/scenes 入库的 sceneId 一致）。 */
export const FOREST_SCENE = 'forest';

/** 森林村民种子定义：与 designCharacter 产出的 CharacterSpec 同约定
 *  （name/personality 中文；visualDescription 英文、只写主体外观，画风/绿幕由生图管线统一追加），
 *  外加 seed 特有的落位与招呼风格。 */
export interface ForestCharacterSeed {
  name: string;
  personality: string;
  visualDescription: string;
  /** 音色目录 id（voice_catalog.ts），按性格气质人工挑选。 */
  voiceId: string;
  greetingStyle: GreetingStyle;
  /** 降生 tile：各自守在森林 POI 附近，绝不压 portal 出口 (20,18)。 */
  position: TilePos;
}

// 森林 POI：小河深潭(41,33) / 林间空地(20,18，也是 portal 出口) / 小山丘(55,30)。
export const FOREST_CHARACTER_SEEDS: ForestCharacterSeed[] = [
  {
    name: '咕咕博士',
    personality: '博学又温和的猫头鹰爷爷，什么都懂一点，说话慢悠悠的，最喜欢给小朋友讲森林里的小知识。',
    visualDescription:
      'a wise old owl professor with fluffy brown and cream feathers, big round amber eyes behind tiny round glasses, wearing a little dark green vest, calm friendly smile',
    voiceId: 'zh-CN-YunyangNeural',
    greetingStyle: 'gentle',
    position: { tileX: 24, tileY: 15 }, // 林间空地旁，让开 portal 出口
  },
  {
    name: '露露',
    personality: '害羞又善良的小鹿姐姐，喜欢在小河边照镜子，熟悉之后会悄悄带你去看最漂亮的花。',
    visualDescription:
      'a shy gentle fawn deer girl with light caramel fur, white spots on her back, big sparkly dark eyes, long eyelashes, a tiny pink flower tucked behind one ear',
    voiceId: 'zh-CN-XiaoxiaoNeural',
    greetingStyle: 'shy',
    position: { tileX: 43, tileY: 35 }, // 小河深潭边
  },
  {
    name: '果果',
    personality: '精力旺盛的小松鼠弟弟，一刻也停不下来，最爱收集松果和捉迷藏，笑声咯咯咯的。',
    visualDescription:
      'an energetic little squirrel boy with bright orange-red fur, a huge fluffy tail, big buck teeth grin, holding a shiny acorn with both paws',
    voiceId: 'zh-CN-YunxiaNeural',
    greetingStyle: 'playful',
    position: { tileX: 53, tileY: 28 }, // 小山丘脚下
  },
  {
    name: '蜂蜜',
    personality: '憨厚热情的小棕熊，力气大心肠软，兜里总揣着蜂蜜罐，见到朋友就想分一口。',
    visualDescription:
      'a chubby friendly brown bear cub with round ears, warm honey-colored belly, holding a small honey pot, big welcoming smile',
    voiceId: 'zh-CN-YunjianNeural',
    greetingStyle: 'warm',
    position: { tileX: 33, tileY: 24 }, // 空地与深潭之间的林间小路
  },
];

export interface SeedForestResult {
  created: { id: string; name: string; spriteAsset: string }[];
  skipped: string[];
  failed: string[];
}

/**
 * 把森林村民种进指定世界：逐个走生图管线（image→cutout→朝向兜底→trim→putAsset），
 * 落库 sceneId=forest + 定义里的固定落位，并 fire-and-forget 触发 idle 动画。
 * 幂等：世界里已有同名角色（任意场景）则跳过——重跑安全，不会种出双胞胎；
 * 立绘不满意用已有的 /worlds/:id/characters/:cid/regen-sprite 原地重生成，别重种。
 * opts.only 限定只种指定名字（低成本单个验证）。单个失败不连坐其它（生图烧钱，能种几个是几个）。
 */
export async function seedForestCharacters(
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  opts: { only?: string[]; toSpriteSheet?: ToSpriteSheet } = {},
): Promise<SeedForestResult> {
  const result: SeedForestResult = { created: [], skipped: [], failed: [] };
  const onlySet = opts.only && opts.only.length > 0 ? new Set(opts.only) : null;
  const existingNames = new Set(store.listCharacters(worldId).map((c) => c.name));
  for (const seed of FOREST_CHARACTER_SEEDS) {
    if (onlySet && !onlySet.has(seed.name)) continue;
    if (existingNames.has(seed.name)) {
      result.skipped.push(seed.name);
      continue;
    }
    try {
      const { hash: assetHash, anchors } = await generateSprite(adapters, seed.visualDescription, store);
      const character: Character = {
        id: randomUUID(),
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
        behaviorScript: { commands: [{ type: 'wander', params: { radius: 5, duration: 8 } }], loop: true },
        position: seed.position,
        sceneId: FOREST_SCENE,
        abilities: [...BASE_ABILITIES],
        relationships: {},
      };
      store.addCharacter(character);
      triggerCharacterAnimation(adapters, store, assetHash, opts.toSpriteSheet);
      result.created.push({ id: character.id, name: seed.name, spriteAsset: assetHash });
    } catch (err) {
      console.warn(`森林村民种入失败（${seed.name}，跳过）：${String(err)}`);
      result.failed.push(seed.name);
    }
  }
  return result;
}
