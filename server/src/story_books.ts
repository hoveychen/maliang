// M2 主线剧情：册定义（代码常量，docs/m2-story-director-design.md §3.3）。
// 册＝章回式短剧：每幕「演出（手作 screenplay）→ 互动（复用现有玩法）→ 奖励（盖章+贴纸）」，
// 整册完结故事角色入住。本文件只有形状与注册表；首册《三只小猪》内容 P3 注册。

/** 册内故事角色档案。seed 时随世界落 roster（预生成立绘 hash 直接引用，不是每世界现生成）。 */
export interface StoryCastDef {
  /** 册内稳定 id（如 'pig_big'）。 */
  castId: string;
  name: string;
  personality: string;
  voiceId: string;
  /** 生成立绘用的外观描述（4 岁向；狼要「憨萌不吓人」）。 */
  visualDescription: string;
  /** 预生成立绘的内容寻址资产 hash（P3 工具跑一次入库后填）。 */
  spriteAsset?: string;
  /** 纯演出角色（狼）：整册完结也不入住、不进任何供给面、不留在场景。 */
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

/** 全部册注册表（bookId → 册）。首册《三只小猪》P3 注册。 */
export const STORY_BOOKS: Record<string, StoryBook> = {};
