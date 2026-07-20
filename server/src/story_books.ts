// M2 主线剧情：册定义（代码常量，docs/m2-story-director-design.md §3.3）。
// 册＝章回式短剧：每幕「演出（手作 screenplay）→ 互动（复用现有玩法）→ 奖励（盖章+贴纸）」，
// 整册完结故事角色入住。首册《三只小猪》在本文件注册（THREE_PIGS）。

import type { TilePos } from './types.ts';
import type { GreetingStyle } from './greetings.ts';

/**
 * 册内故事角色档案。seed 时随世界落 roster（story_seed.seedStoryCharacters，立绘走
 * generateSprite 服务端管线现生成；prod 实际单世界，
 * seed 只跑一次，成本与确定性都可控）。
 */
export interface StoryCastDef {
  /** 册内稳定 id（如 'pig_big'）。 */
  castId: string;
  name: string;
  personality: string;
  voiceId: string;
  /** 生成立绘用的外观描述（英文、只写主体，画风/绿幕由生图管线统一追加；狼要「憨萌不吓人」）。 */
  visualDescription: string;
  /** 降生 tile（册所在场景内）。狼站得远离村心——「不留在场景」以站位+零供给近似。 */
  position: TilePos;
  greetingStyle: GreetingStyle;
  /** 纯演出角色（狼）：整册完结也不入住、不进任何供给面。 */
  noResidence?: boolean;
}

/**
 * 互动幕：只复用现有玩法之一，完成判定零新增——
 * task 走 activeTask 形状（completeTaskOnEvent 家族），build 挂 B1 create_build 完成点。
 */
export type StoryInteraction =
  | {
      kind: 'build';
      /** B1 积木蓝图 id（build_blueprints.ts）：互动＝帮小猪拼完这个蓝图。 */
      blueprintId: string;
      /** 发起互动的册内角色（ask/thanks 由它说）。 */
      npcCastId: string;
      ask: string;
      thanks: string;
    }
  | {
      kind: 'task';
      type: 'deliver' | 'bring' | 'visit';
      npcCastId: string;
      /** deliver/bring：对象册内角色。 */
      targetCastId?: string;
      /** visit：地点名（客户端 POI 判定）。 */
      locationName?: string;
      /** deliver：要带的话。 */
      message?: string;
      ask: string;
      thanks: string;
    };

/** 一幕。interaction 缺省＝演完直接收场推进（尾声谢幕：无互动无盖章，整册完结入住）。 */
export interface StoryChapter {
  /** SCREENPLAYS 注册名（story_pigs_1 …），checkScreenplay 门禁过审的手作剧本。 */
  screenplay: string;
  interaction?: StoryInteraction;
  /** 本幕盖章款式（STAMP_STYLES 之一，纯演出）。无互动的幕不盖章，可省。 */
  stampStyle?: string;
  /** 本幕纪念贴纸（内置贴纸 id，addToBag 发放）；缺省＝只盖章。 */
  sticker?: string;
}

export interface StoryBook {
  id: string;
  title: string;
  /** 演出与故事角色所在场景（首册 village）。 */
  sceneId: string;
  /** 门口的故事角色（cast 里的 castId）＝触发入口：未入住也可搭话，搭话即触发。 */
  gateCastId: string;
  /** 全部故事角色（三只小猪＋狼）。 */
  cast: StoryCastDef[];
  chapters: StoryChapter[];
}

// ── 首册《三只小猪》（village，3 幕＋尾声，docs/m2-story-director-design.md §5）──
// 叙事编排：幕 3 演出是「狼逼近、砖房没盖完、向小朋友求助」→ build 互动盖砖房，
// 「狼吹不倒+滑稽跑掉」放尾声当互动的回报——保住 build 的因果顺序（帮了忙才守得住）。
// 幕 1 的 visit 不带 locationName：物化时按场景现有地点现选（「稻草被吹到那边去了」），
// 村庄没有「草房废墟」POI，话术写成地点无关。

export const THREE_PIGS: StoryBook = {
  id: 'three_pigs',
  title: '三只小猪',
  sceneId: 'village',
  gateCastId: 'pig_big',
  cast: [
    {
      castId: 'pig_big',
      name: '猪大哥',
      personality: '稳重可靠的猪大哥，说话慢条斯理，最会照顾两个弟弟，相信把事情做扎实才不怕大灰狼。',
      voiceId: 'zh-CN-YunyangNeural',
      visualDescription:
        'a sturdy big brother pig with round pink body, wearing blue denim overalls and a tiny straw hat, holding nothing, kind steady smile, standing upright like a person',
      position: { tileX: 30, tileY: 46 },
      greetingStyle: 'gentle',
    },
    {
      castId: 'pig_mid',
      name: '猪二哥',
      personality: '风风火火的猪二哥，嗓门大爱咋呼，干活图快，被大灰狼吓过之后最佩服大哥的砖房子。',
      voiceId: 'zh-CN-YunxiNeural',
      visualDescription:
        'an energetic middle brother pig with round pink body, wearing a green t-shirt, cheerful wide grin, ears perked up, standing upright like a person',
      position: { tileX: 33, tileY: 45 },
      greetingStyle: 'warm',
    },
    {
      castId: 'pig_small',
      name: '猪小弟',
      personality: '软乎乎爱撒娇的猪小弟，贪玩怕黑，草房子被吹倒后总跟在哥哥们身后，最喜欢跟小朋友玩。',
      voiceId: 'zh-TW-HsiaoChenNeural',
      visualDescription:
        'a small baby brother pig with chubby round pink body, wearing a yellow bib with a flower pattern, big sparkly innocent eyes, shy sweet smile, standing upright like a person',
      position: { tileX: 28, tileY: 48 },
      greetingStyle: 'shy',
    },
    {
      castId: 'wolf',
      name: '大灰狼',
      personality: '爱吹牛皮的大灰狼，整天鼓着腮帮子想吹倒房子，其实笨手笨脚一吹就头晕，凶不起来只剩滑稽。',
      voiceId: 'zh-CN-YunjianNeural',
      visualDescription:
        'a goofy chubby grey wolf with soft fluffy fur, puffed round cheeks like blowing air, crossed silly eyes, tiny stubby tail, clumsy harmless cartoon look, not scary at all, standing upright like a person',
      position: { tileX: 8, tileY: 10 },
      greetingStyle: 'playful',
      noResidence: true,
    },
  ],
  chapters: [
    {
      screenplay: 'story_pigs_1',
      interaction: {
        kind: 'task',
        type: 'visit',
        npcCastId: 'pig_small',
        ask: '我的草房子被大灰狼吹倒啦，稻草吹得到处都是……你帮我去那边看一看好不好？',
        thanks: '你帮我看过啦！稻草没了就没了，下次我要盖更结实的房子！',
      },
      stampStyle: 'star',
      sticker: 'story_straw',
    },
    {
      screenplay: 'story_pigs_2',
      interaction: {
        kind: 'task',
        type: 'deliver',
        npcCastId: 'pig_big',
        targetCastId: 'pig_small',
        message: '快来大哥的砖房，我们等你！',
        ask: '猪小弟吓得躲起来啦……请你帮我把这句话带给他：快来大哥的砖房，我们等你！',
        thanks: '太好啦，猪小弟听到啦！一家人就要整整齐齐的！',
      },
      stampStyle: 'medal',
      sticker: 'story_plank',
    },
    {
      screenplay: 'story_pigs_3',
      interaction: {
        kind: 'build',
        blueprintId: 'house',
        npcCastId: 'pig_big',
        ask: '大灰狼快追来啦，砖房子还没盖完……请你帮我们一起把房子拼起来好不好？',
        thanks: '房子盖好啦！这是全村最结实的房子，多亏了你！',
      },
      stampStyle: 'heart',
      sticker: 'story_brick',
    },
    { screenplay: 'story_pigs_end' }, // 尾声谢幕：无互动无盖章，演完整册完结入住
  ],
};

/** 全部册注册表（bookId → 册）。 */
export const STORY_BOOKS: Record<string, StoryBook> = { [THREE_PIGS.id]: THREE_PIGS };

/**
 * 故事角色在 roster 里的 characterId 约定（seed 与选角共用同一推导，不查表）：
 * 同一册同一 castId 在任何世界都是同一个 id——选角（buildStoryStageOpts）按它直取角色。
 */
export function storyCharacterId(bookId: string, castId: string): string {
  return `story_${bookId}_${castId}`;
}

/**
 * 册 → 预烧音包目录约定（bookId 'three_pigs' → 'story_three_pigs'）。以前是隐式散落在
 * 客户端 story_voice.gd 与服务端测试里的字符串常量，现显式化为单一来源：
 * - 服务端：`assets/voice/${storyVoiceDir(book.id)}/lines.json` 定位该册预烧清单；
 * - 客户端 StoryVoice 扫 `res://assets/voice/story_*` 目录（同源约定：每册目录都以 `story_` 前缀）。
 * 加一册只需把台词烧进 `assets/voice/story_<新册 id>/`，无需任何映射登记。
 */
export function storyVoiceDir(bookId: string): string {
  return `story_${bookId}`;
}

/** 未入住的故事角色（供给面早返回的统一判据：狼/还没演到入住的小猪不漏话不派活不迎客）。 */
export function isUnsettledStoryRole(c: { storyRole?: { resident: boolean } }): boolean {
  return !!c.storyRole && !c.storyRole.resident;
}
