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

// ── 首册《三只小猪》（village_forest 合并大场景，3 幕＋尾声，docs/m2-story-director-design.md §5）──
// 叙事编排：幕 3 演出是「狼逼近、砖房没盖完、向小朋友求助」→ build 互动盖砖房，
// 「狼吹不倒+滑稽跑掉」放尾声当互动的回报——保住 build 的因果顺序（帮了忙才守得住）。
// 幕 1 的 visit 不带 locationName：物化时按场景现有地点现选（「稻草被吹到那边去了」），
// 村庄没有「草房废墟」POI，话术写成地点无关。
// s1-hood-activate P1：B 全量合并——从退役单场景 village(75 格) 迁进主场景 village_forest(100 格)。
// 坐标重锚进村庄核心近端带（z<40，中央广场 x∈[16,24] z∈[12,20]，见 terrain_map._paint_village_forest）：
// 小猪群聚广场好找、狼在广场西巷自己一角。

export const THREE_PIGS: StoryBook = {
  id: 'three_pigs',
  title: '三只小猪',
  sceneId: 'village_forest',
  gateCastId: 'pig_big',
  cast: [
    {
      castId: 'pig_big',
      name: '猪大哥',
      personality: '稳重可靠的猪大哥，说话慢条斯理，最会照顾两个弟弟，相信把事情做扎实才不怕大灰狼。',
      voiceId: 'zh-CN-YunyangNeural',
      visualDescription:
        'a sturdy big brother pig with round pink body, wearing blue denim overalls and a tiny straw hat, holding nothing, kind steady smile, standing upright like a person',
      position: { tileX: 20, tileY: 15 },
      greetingStyle: 'gentle',
    },
    {
      castId: 'pig_mid',
      name: '猪二哥',
      personality: '风风火火的猪二哥，嗓门大爱咋呼，干活图快，被大灰狼吓过之后最佩服大哥的砖房子。',
      voiceId: 'zh-CN-YunxiNeural',
      visualDescription:
        'an energetic middle brother pig with round pink body, wearing a green t-shirt, cheerful wide grin, ears perked up, standing upright like a person',
      position: { tileX: 18, tileY: 17 },
      greetingStyle: 'warm',
    },
    {
      castId: 'pig_small',
      name: '猪小弟',
      personality: '软乎乎爱撒娇的猪小弟，贪玩怕黑，草房子被吹倒后总跟在哥哥们身后，最喜欢跟小朋友玩。',
      voiceId: 'zh-TW-HsiaoChenNeural',
      visualDescription:
        'a small baby brother pig with chubby round pink body, wearing a yellow bib with a flower pattern, big sparkly innocent eyes, shy sweet smile, standing upright like a person',
      position: { tileX: 22, tileY: 13 },
      greetingStyle: 'shy',
    },
    {
      castId: 'wolf',
      name: '大灰狼',
      personality: '爱吹牛皮的大灰狼，整天鼓着腮帮子想吹倒房子，其实笨手笨脚一吹就头晕，凶不起来只剩滑稽；心里又馋又孤单，最想的其实是有人陪他一起玩。',
      voiceId: 'zh-CN-YunjianNeural',
      visualDescription:
        'a goofy chubby grey wolf with soft fluffy fur, puffed round cheeks like blowing air, crossed silly eyes, tiny stubby tail, clumsy harmless cartoon look, not scary at all, standing upright like a person',
      // 广场西巷一角自己的小窝（小猪群西侧，x∈[8,15] z∈[15,17] 可行走带）：故事后翻 resident 成可搭话村民，孩子好找他玩。
      position: { tileX: 11, tileY: 16 },
      greetingStyle: 'playful',
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

// ── 第二册《小红帽》（village_forest 合并大场景，1 幕 + 尾声）──────────────────
// 第一季册 2（docs/season-1-outline.md §4）。语文（听 → 复述）+ 引路认路。
// 场景是新的 village+forest 合并大场景（100 格，docs/s1-merged-scene-layout.md）：小红帽在村里
// 搭话触发，互动是 task:visit 外婆家——点点飞前面 guide_to 引路，孩子沿穿林小径把点心送到外婆家
// （poi_grandma）。尾声在外婆家演出，点点请孩子把故事讲给外婆听（复述，剧本内 stage.prompt，
// 零挫败不打分），整册完结小红帽与外婆入住。无狼——避免与《三只小猪》已改邪归正的狼设定打架
// （outline §4：狼版弱化/去惊吓）。guide_to 引路的互动接线 + souvenir 贴纸 story_basket 在 s1-hood P4。

export const LITTLE_RED_HOOD: StoryBook = {
  id: 'hood',
  title: '小红帽',
  sceneId: 'village_forest',
  gateCastId: 'red_hood',
  cast: [
    {
      castId: 'red_hood',
      name: '小红帽',
      personality: '戴着红帽子、活泼懂事的小姑娘，最爱外婆，答应了妈妈就一定把点心送到；路上好奇又不贪玩。',
      voiceId: 'zh-CN-XiaoyiNeural',
      visualDescription:
        'a cheerful little girl with a bright red hooded cape over a simple dress, holding a small basket of treats, rosy cheeks and a sweet smile, standing upright like a person',
      // 村庄核心近端带（广场旁），gate 角色好找、搭话即触发。
      position: { tileX: 25, tileY: 18 },
      greetingStyle: 'warm',
    },
    {
      castId: 'granny',
      name: '外婆',
      personality: '住在树林边小屋里的慈祥外婆，说话慢悠悠暖融融，见到小红帽和小朋友来看她，病都好了一半。',
      voiceId: 'zh-CN-XiaoxiaoNeural',
      visualDescription:
        'a kindly old grandmother with silver hair in a bun, round glasses, a warm shawl and apron, gentle wrinkled smile, standing upright like a person',
      // 穿林小径尽头的外婆家小屋前（poi_grandma 附近）。
      position: { tileX: 67, tileY: 62 },
      greetingStyle: 'gentle',
    },
  ],
  chapters: [
    {
      screenplay: 'story_hood_1',
      interaction: {
        kind: 'task',
        type: 'visit',
        npcCastId: 'red_hood',
        locationName: '外婆家',
        ask: '外婆生病啦，我要给她送这篮点心……你陪我一起走小路去外婆家好不好？点点会飞在前面带路。',
        thanks: '我们把点心送到外婆家啦！谢谢你一路陪着我、没让我迷路。',
      },
      stampStyle: 'heart',
      sticker: 'story_basket',
    },
    { screenplay: 'story_hood_end' }, // 尾声谢幕：讲给外婆听（复述）+ 整册完结入住
  ],
};

// ── 第五册《绿野仙踪》（独立场景 oz·奥兹黄砖路，2 幕 + 尾声）────────────────────
// 第一季册 5（docs/season-1-outline.md §4/§6）。英语暴露（桃乐丝天生说英文）+「同一个词用在很多地方」复用种子。
// 老板 2026-07-21 拍板：**另置独立场景**（不进 village_forest 合并图，见 s1-merged-scene-layout §0）——
// 复活休眠的多场景/portal 基建，村庄核心（village_forest）加一座通往 oz 的传送门，孩子走进去就到「远方」。
// gate=桃乐丝：她被大风从很远的地方吹来、只会说英文，在黄砖路上找回家的路，搭话即触发。
// 互动两幕都是 task:deliver——帮桃乐丝把一句最简单的英文问候（'Hello!' / 'Thank you!'）带给路那头的新朋友；
// 孩子说中文也算完成（英语纪律：暴露优先、输出不强求、绝无跟读打分，outline §4/§138）。点点在旁用中文轻声翻译。
// 尾声在翡翠城演出，点点请孩子把桃乐丝的故事讲给大家听（复述，stage.prompt），
// 整册完结桃乐丝 + 稻草人 + 铁皮人**三人都入住**（老板 2026-07-21 定：稻草人/铁皮人都留下当常驻）。
// 台词避开英文撇号（story_content.test 的 spokenLines 用单引号+[^']+ 抠台词，'I am' 不写 'I'm'）。

export const WIZARD_OF_OZ: StoryBook = {
  id: 'oz',
  title: '绿野仙踪',
  sceneId: 'oz',
  gateCastId: 'dorothy',
  cast: [
    {
      castId: 'dorothy',
      name: '桃乐丝',
      personality: '被一阵大风从很远的地方吹到这里的小姑娘，只会说英文，有点想家但很勇敢，一心想找到回家的路；对什么都好奇，遇到新朋友就热情打招呼。',
      voiceId: 'en-US-AnaNeural',
      visualDescription:
        'a brave little girl with brown braided pigtails, wearing a blue gingham pinafore dress over a white blouse, holding a small woven basket, shiny red shoes, bright curious eyes and a warm smile, standing upright like a person',
      // 黄砖路入口（portal 落点近端），gate 角色好找、搭话即触发。terrain _paint_oz 对齐（P3）。
      position: { tileX: 16, tileY: 16 },
      greetingStyle: 'warm',
    },
    {
      castId: 'scarecrow',
      name: '稻草人',
      personality: '玉米地里憨厚爱笑的稻草人，一直想要一个聪明的脑袋好帮上忙；其实点子最多、最热心，遇到难题总第一个举手。',
      voiceId: 'zh-CN-YunxiNeural',
      visualDescription:
        'a friendly straw scarecrow with a round burlap-sack head and a stitched smile, wearing a patched plaid shirt stuffed with straw, floppy pointed hat, straw poking from the sleeves, cheerful and harmless, standing upright like a person',
      // 黄砖路中段玉米地空地（P3 _paint_oz 玉米地锚点）。
      position: { tileX: 36, tileY: 34 },
      greetingStyle: 'playful',
    },
    {
      castId: 'tinman',
      name: '铁皮人',
      personality: '黄砖路边有点生锈、说话一本正经的铁皮人，最想要一颗温暖的心；嘴上硬邦邦，其实最容易感动、最会照顾人。',
      voiceId: 'zh-CN-YunyangNeural',
      visualDescription:
        'a shiny tin man made of riveted silver metal with a small funnel hat, a red heart painted on his chest, round gentle eyes and a soft smile, a tiny oil can at his side, friendly and not scary, standing upright like a person',
      // 黄砖路尽头翡翠城广场近端（P3 _paint_oz 翡翠城锚点）。
      position: { tileX: 56, tileY: 54 },
      greetingStyle: 'gentle',
    },
  ],
  chapters: [
    {
      screenplay: 'story_oz_1',
      interaction: {
        kind: 'task',
        type: 'deliver',
        npcCastId: 'dorothy',
        targetCastId: 'scarecrow',
        message: 'Hello!',
        ask: '我在找回家的路，看见玉米地里的稻草人啦！你帮我把一句英文的问候带给他好不好——就说：Hello！（你好）',
        thanks: '稻草人听到 Hello 啦，他好开心！谢谢你帮我交上了第一个新朋友。',
      },
      stampStyle: 'star',
      sticker: 'story_ruby',
    },
    {
      screenplay: 'story_oz_2',
      interaction: {
        kind: 'task',
        type: 'deliver',
        npcCastId: 'dorothy',
        targetCastId: 'tinman',
        message: 'Thank you!',
        ask: '生了锈的铁皮人帮我们指了路，我想谢谢他……你帮我把这句英文带给他好吗——就说：Thank you！（谢谢你）',
        thanks: '铁皮人听到 Thank you，心里暖暖的！有你在，说英文一点都不难。',
      },
      stampStyle: 'medal',
      sticker: 'story_emerald',
    },
    { screenplay: 'story_oz_end' }, // 尾声谢幕：讲给大家听（复述）+ 桃乐丝/稻草人/铁皮人三人入住
  ],
};

// ── 第四册《龟兔赛跑》（village_forest 合并大场景，1 幕 + 尾声）──────────────────
// 第一季册 4（docs/season-1-outline.md §4）。管理种子（先做哪个 / 用什么节奏）+ 二选一。
// 场景复用现有 village_forest（100 格）东缘直跑道分区（x∈[87,89] z∈[8,92]，terrain_map
// _paint_village_forest 已画骨架、scene_compose _deco_kind_village_forest 已排除路面/缓冲两侧）。
// gate = 兔子，在村庄核心广场旁搭话触发；幕 1 演出「村口约赛跑·兔子夸口」，互动是 task:visit 跑道
// ——点点飞前面 guide_to 引路，孩子走到东缘跑道给龟兔加油（poi_race，s1-race P4 加）。尾声在跑道演出
// 真正的比赛：点点问「给谁加油」孩子点乌龟/兔子（stage.once tap），老板拍板殊途同归——点谁都是
// 兔子睡过头、乌龟稳步先到、大家做朋友（零挫败，管理种子靠「看见稳步的好」隐性传递）；结尾复述、
// 整册完结龟兔入住。加油小旗贴纸 story_cheer_flag 在 P3，跑道 POI + 布景 prop 包在 P4。

export const TORTOISE_HARE: StoryBook = {
  id: 'tortoise_hare',
  title: '龟兔赛跑',
  sceneId: 'village_forest',
  gateCastId: 'hare',
  cast: [
    {
      castId: 'tortoise',
      name: '乌龟',
      personality: '慢性子、稳稳当当的乌龟，从不着急，相信一步一步就能走到终点；心地好，输赢都笑呵呵。',
      voiceId: 'zh-TW-YunJheNeural',
      visualDescription:
        'a steady friendly tortoise with a round green shell, short sturdy legs, calm gentle smile, wearing a tiny red sport headband, standing upright like a person',
      // 村庄核心广场旁（近端 z<38），gate 好找、搭话即触发；与兔子并排「村口约赛跑」。
      position: { tileX: 24, tileY: 19 },
      greetingStyle: 'gentle',
    },
    {
      castId: 'hare',
      name: '兔子',
      personality: '风风火火爱夸口的兔子，跑得飞快、最爱抢先，比赛时忍不住偷懒睡个觉；其实心不坏，输了也大方认输、和好如初。',
      voiceId: 'zh-CN-YunxiNeural',
      visualDescription:
        'a speedy white rabbit with long floppy ears, bright confident grin, wearing a blue racing vest with a number, one paw on hip boasting, standing upright like a person',
      position: { tileX: 22, tileY: 18 },
      greetingStyle: 'playful',
    },
  ],
  chapters: [
    {
      screenplay: 'story_th_1',
      interaction: {
        kind: 'task',
        type: 'visit',
        npcCastId: 'hare',
        locationName: '跑道',
        ask: '走呀走呀，我们去东边的跑道比赛！你陪我一起过去给我们加油好不好？点点会飞在前面带路。',
        thanks: '你也来到跑道啦！有你加油，这场比赛一定特别好玩！',
      },
      stampStyle: 'medal',
      sticker: 'story_cheer_flag',
    },
    { screenplay: 'story_th_end' }, // 尾声：跑道上真正的比赛（二选一殊途同归）+ 复述 + 整册完结入住
  ],
};

/** 全部册注册表（bookId → 册）。 */
export const STORY_BOOKS: Record<string, StoryBook> = {
  [THREE_PIGS.id]: THREE_PIGS,
  [LITTLE_RED_HOOD.id]: LITTLE_RED_HOOD,
  [WIZARD_OF_OZ.id]: WIZARD_OF_OZ,
  [TORTOISE_HARE.id]: TORTOISE_HARE,
};

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
