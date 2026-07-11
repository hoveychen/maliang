// maliang 后端核心类型与造角色协议。客户端是 GDScript，不共享代码，
// 但 WS/REST 协议字段以本文件为准（见 docs/tech-design.md §5.1、§6）。

export interface ChatTurn {
  role: 'child' | 'npc';
  text: string;
  ts: number;
}

export interface BehaviorCommand {
  type: string; // move_to | wander | wait | follow | stop_follow | do_action | chat_with | deliver_message | give | say | emote | face | create_character
  params: Record<string, unknown>;
}

export interface BehaviorScript {
  commands: BehaviorCommand[];
  loop: boolean;
}

/** 所有村民共有的基础交互能力（与 scripts/behavior_executor.gd 的指令集对齐）。
 * 存量角色 abilities 里可能只有旧的两项，意图 prompt 按「基础集 ∪ 角色自带」取并集，免数据迁移。 */
export const BASE_ABILITIES = ['move_to', 'follow', 'stop_follow', 'do_action', 'chat_with', 'deliver_message'];

/** 要「走过去」才能兑现的能力（stop_follow 只有在能 follow 时才有意义，一并算入）。 */
export const LOCOMOTION_ABILITIES = ['move_to', 'follow', 'stop_follow', 'chat_with', 'deliver_message'];

/**
 * 喂给意图 LLM 的能力集：基础集 ∪ 角色自带，小仙子再减去所有需要走动的能力。
 *
 * 小仙子是贴身随从——客户端 _run_behavior 对 is_fairy 早返回，移动脚本一律丢弃。把 move_to/follow
 * 这类能力写进她的 prompt，LLM 就会让她「去风车那儿」：孩子听见一句「好呀」，人却纹丝不动。
 * 与其在下游拦，不如源头上不给。她保留就地能做的 do_action 与看家本领 create_character/create_prop。
 */
export function effectiveAbilities(c: { abilities: string[]; isFairy: boolean }): string[] {
  const all = [...new Set([...BASE_ABILITIES, ...c.abilities])];
  return c.isFairy ? all.filter((a) => !LOCOMOTION_ABILITIES.includes(a)) : all;
}

// ── 奖赏系统：小红花代币 + 集邮盖章（替换旧的 8 种贴纸 + give 转赠，见 docs/reward-flower-design.md）──

/** 小红花上限（3×3 格）。 */
export const MAX_FLOWERS = 9;
/** 每满 N 个盖章换 1 朵小红花。 */
export const STAMPS_PER_FLOWER = 3;
/** 冷启动/旧档迁移初始赠送的小红花数（够造一次物+一次角色还剩一朵试错）。 */
export const INITIAL_FLOWERS = 3;

/**
 * 无 playerId 时的匿名玩家键（老客户端 / 直连调试不带 playerId）。
 * 所有匿名连接共用这一个钱包与委托——与「按玩家分」之前的行为一致，不因缺身份而崩。
 */
export const ANON_PLAYER = '';

/**
 * 玩家钱包：唯一货币「小红花」+ 集邮盖章进度。随世界持久化（复用旧 inventory 列，存 Wallet JSON）。
 * 经济：完成任一委托盖 1 章；每满 3 章换 1 朵花（纯累加，不因中断清零）；造物/造角色各扣 1 朵。
 */
export interface Wallet {
  /** 小红花，0..MAX_FLOWERS。造物/造角色消费出口。 */
  flowers: number;
  /**
   * 当前未结算的盖章数，常态 0..STAMPS_PER_FLOWER-1。
   * 满 9 花溢出时可短暂停在 STAMPS_PER_FLOWER（=一组已满待兑换），等花被花掉腾出格子立即补升（见 settleWallet）。
   */
  stampProgress: number;
  /** 累计盖过的章数（只增，集邮簿/成就展示用）。 */
  stampsTotal: number;
}

/** 集邮盖章款式目录：完成委托时随机挑一款（纯演出，不影响经济）。id 稳定入存档，客户端映射到 AIGC 盖章图（P5）。 */
export const STAMP_STYLES: readonly string[] = ['star', 'smile', 'paw', 'medal', 'heart'];

/** 委托类型：完成判定全部是客户端确定性事件（送达回调/相邻/到点），不靠 LLM 猜。 */
export type TaskType = 'deliver' | 'bring' | 'visit';

/** 进行中的委托。同一时刻至多一个（幼儿单任务心智，完成判定也无歧义）。完成 = 盖 1 章。 */
export interface ActiveTask {
  id: string;
  type: TaskType;
  npcId: string; // 委托人（完成后由它庆祝/表扬）
  npcName: string;
  targetName?: string; // deliver/bring：对象角色名
  locationName?: string; // visit：地点名（客户端 POI 判定）
  message?: string; // deliver：要带的话
  stampStyle: string; // 完成时盖的章款式 id（STAMP_STYLES 之一，纯演出）
}

/** LLM 从玩家意图产出的角色设定（落地前）。 */
export interface CharacterSpec {
  name: string;
  personality: string;
  visualDescription: string;
  voiceId: string;
  scale: number;
  abilities: string[];
}

/** 落地后的完整角色。 */
/**
 * 环面世界的边长（tile 数），与客户端 WorldGrid.GRID_TILES 必须一致。
 * 坐标上报的唯一合法域是 [0, GRID_TILES)²——早年 1000×1000 大世界留下的 tile 500 在此域外。
 */
export const GRID_TILES = 75;

/** 世界正中心 tile：新角色/小神仙的降生点（客户端首次上报前的占位值）。 */
export const WORLD_CENTER_TILE: TilePos = { tileX: Math.floor(GRID_TILES / 2), tileY: Math.floor(GRID_TILES / 2) };

export interface TilePos {
  tileX: number;
  tileY: number;
}

/** 场景里的一个地点（喂意图 LLM 归一「去某地」；trigger 由客户端映射到仙子台词）。 */
export interface ScenePoi {
  tile: [number, number];
  radius: number;
  trigger: string;
  name: string;
  aliases: string[];
}

/** 场景之间的传送点（模型 B：同一个 world 内的区域之间走动）。 */
export interface ScenePortal {
  tile: [number, number];
  radius: number;
  toScene: string;
  toTile: [number, number];
}

/**
 * 场景 = 世界里的一片区域（一张地图）。见 docs/multi-scene-design.md 模型 B。
 * terrainAsset 是地形二进制在内容寻址资产库里的 hash，同时充当版本号：
 * 地形变了 hash 就变，客户端据此判缓存，天然不存在版本协商问题。
 */
export interface Scene {
  worldId: string;
  sceneId: string;
  name: string;
  terrainAsset: string;
  gridTiles: number;
  pois: ScenePoi[];
  portals: ScenePortal[];
  /**
   * 地形矩阵版本（单调递增，tile 编辑每次 +1）。客户端缓存键与 terrain_patch
   * 对齐依据：patch 必须恰是本地版本 +1，否则全量重拉。0 = 尚未有矩阵 blob。
   */
  terrainVersion: number;
}

/** 单场景时代的场景 id：存量角色/物件全部隐含属于它。 */
export const DEFAULT_SCENE = 'village';

/**
 * 物品实体定义（万物皆物品，见 docs/scene-item-refactor-design.md §2.1）。
 * 内置布置物（树/民居/水井…）与语音造物同一张表：内置项是代码常量 seed（items.ts），
 * 语音造物落 items 表（world_id 归属）。其它一切地方（地形矩阵 palette、背包）
 * 都只是对本实体 id 的引用——同一实体可被任意多个 tile 引用（克隆）。
 */
export interface ItemDef {
  /** 内置项用众所周知 id（'tree_puff_a'…），造物用生成 id。 */
  id: string;
  /** null = 内置全局定义；非空 = 该 world 的语音造物。 */
  worldId: string | null;
  /** 显示名（"苹果树"/孩子起的名字）。 */
  name: string;
  /**
   * 渲染引用，前缀分发：
   *   'baked:<name>'   客户端 SDF 烘焙 mesh（assets/sdf_props/baked/<name>.res，MultiMesh 合批）
   *   'kaykit:<name>'  KayKit gltf 场景（客户端 preload 映射表）
   *   'sdf_res:<name>' 打包内 SDF spec（assets/sdf_props/<name>.json）
   *   'sdf_inline'     spec 字段内联（语音造物）
   */
  renderRef: string;
  /** sdf_inline 时的 SDF spec（结构见 sdf_prop.ts）。 */
  spec?: import('./sdf_prop.ts').SdfPropSpec;
  /** 占地（tile），锚点居中展开（奇数边）；1×1 / 3×3。 */
  footprintW: number;
  footprintH: number;
  /** false = 可穿行纯点缀（草丛），不参与占用。 */
  blocking: boolean;
  /** 允许压在路面上（水井坐镇广场）。 */
  pathOk: boolean;
  /** SDF 物件围绕锚点的游走半径（米），0 = 不动。 */
  wander: number;
}

/** tile 是否落在环面世界内（整数且在 [0, GRID_TILES)）。越界/非整数一律拒收，不做 wrap。 */
export function isValidTile(tile: TilePos): boolean {
  const inRange = (v: number) => Number.isInteger(v) && v >= 0 && v < GRID_TILES;
  return inRange(tile.tileX) && inRange(tile.tileY);
}

export interface Character {
  id: string;
  worldId: string;
  isFairy: boolean;
  name: string;
  personality: string;
  voiceId: string;
  /** 进对话时的招呼风格（warm|shy|playful|gentle）；缺省按 id 稳定哈希落到一种，见 greetings.ts。 */
  greetingStyle?: string;
  appearance: { visualDescription: string; spriteAsset: string; scale: number };
  memory: string[];
  chatHistory: ChatTurn[];
  state: string;
  behaviorScript: BehaviorScript;
  /** 环面 tile 坐标。空间权威在客户端：这里存的是客户端 positions_report 上报的最后位置，重载时读回。 */
  position: TilePos;
  /**
   * 角色所在场景（模型 B 多场景，见 docs/multi-scene-design.md）。
   * 缺省/undefined = DEFAULT_SCENE（单场景时代的存量角色，迁移时补齐为 village）。
   * 随 positions_report 携带的 sceneId 更新——上报只带当前场景里的角色，故场景跟着位置走。
   */
  sceneId?: string;
  abilities: string[];
  relationships: Record<string, string>;
}

/** 造角色编排的阶段，顺序固定，用于进度推送。 */
export type GenStage = 'spec' | 'moderate_text' | 'image' | 'cutout' | 'persist';

export const GEN_STAGES: readonly GenStage[] = ['spec', 'moderate_text', 'image', 'cutout', 'persist'];

export interface CreateCharacterInput {
  worldId: string;
  intentText: string; // M1 文字驱动；M2 由 ASR 产出
  byFairy: boolean;
  position?: TilePos;
  /** 新伙伴降生的场景；缺省=DEFAULT_SCENE（单场景时代/未指定时落 village）。 */
  sceneId?: string;
}

export interface ModerationResult {
  allowed: boolean;
  reason?: string;
}

/** 意图路由结果：闲聊还是预设能力指令。 */
export interface IntentResult {
  kind: 'chat' | 'command';
  replyText: string; // 闲聊回应 / 指令的口头确认（中文）
  behaviorScript?: BehaviorScript; // command 时
  emotion: string; // happy | think | wave | ...（图标化情绪）
  /** 指令执行者的名字：小朋友点名让「别的」角色做时才有（如对小绿说「小蓝跟我来」）。缺省=正在对话的角色。 */
  performerName?: string;
  /** LLM 在这句回应里发起了上下文给的委托候选（taskCandidate）→ 服务端把它设为进行中。 */
  offerTask?: boolean;
}

/** 意图路由的上下文（喂给 LLM）。 */
export interface IntentContext {
  characterName: string;
  personality: string;
  abilities: string[];
  recentHistory?: ChatTurn[]; // 近 N 轮对话，给角色上下文让回应连贯
  /** 角色对当前玩家的长期记忆（带分类，注入时按 kind 分组）。 */
  memory?: { text: string; kind: MemoryKind }[];
  /** 世界里的其他角色花名册（不含自己/小神仙）：让 LLM 能把「小蓝跟我来」「去找小绿聊天」对上真实角色名。 */
  worldCharacters?: { id: string; name: string }[];
  /** 世界地点名清单（客户端 world_info 上报的 POI 名）：move_to 的 location_name 优先归一到这些名字。 */
  locations?: string[];
  /** 进行中的委托（若有）：让角色记得催/答疑，且不再发起新委托。 */
  activeTask?: ActiveTask;
  /** 可发起的委托候选（无进行中委托时服务端生成）：LLM 觉得时机合适就用自己口吻发起并置 offerTask。 */
  taskCandidate?: ActiveTask;
  /** 稳定的会话缓存键（`world:character:player`）：作 OpenRouter session_id 做 sticky routing，命中 prompt cache。 */
  cacheKey?: string;
}

/** 会话（Visit）结束时让角色「自己决定记什么」的上下文（extractMemory 用）。 */
export interface MemoryExtractionContext {
  characterName: string;
  personality: string;
  /** 本次会话（Visit）里与该角色的整段对话增量（多轮），会话结束批量抽一次。 */
  turns: { child: string; npc: string }[];
  existingMemory: string[]; // 已记住的，用于去重/避免重复记
  /** 稳定的会话缓存键（`world:character:player`）：作 OpenRouter session_id 做 sticky routing。 */
  cacheKey?: string;
}

/** voice_input 编排的返回（推给客户端 character_response）。 */
export interface VoiceResponse {
  characterId: string;
  transcript: string;
  replyText: string;
  /** 非流式：资源 hash（/assets/:hash）。流式时为空串，完整音频 hash 由 tts_end 携带。 */
  ttsAsset: string;
  behaviorScript?: BehaviorScript;
  emotion: string;
  /** 流式 TTS：character_response 先行，音频随 tts_chunk 推送（PCM16，mime 见 ttsMime）。 */
  ttsStreaming?: boolean;
  ttsMime?: string; // 如 audio/L16;rate=24000，客户端据此设采样率
  /** 出声角色的音色 id：clientTts 客户端据此映射 edge-tts 音色本地合成（见 docs/edge-tts-client-design.md）。 */
  voiceId?: string;
  /** behaviorScript 的执行者角色 id：小朋友点名让别的角色做时才有，缺省=characterId。 */
  performerId?: string;
  /** 这句回应里新发起的委托（LLM offerTask 且服务端已设为进行中）→ 客户端显示任务提示。 */
  task?: ActiveTask;
  /** create_prop 意图的物件描述：不下发客户端，由 WS 层摘走并异步造物（prop_created 推送）。 */
  propRequest?: string;
  /** create_character 意图的新伙伴描述：不下发客户端，由 WS 层摘走并异步造角色（gen_progress/gen_complete 推送）。仅小仙子有此能力。 */
  characterRequest?: string;
  /** 主动招呼（进对话对方先开口）：transcript 为空且非玩家发起，客户端据此跳过「没听清」提示。 */
  greeting?: boolean;
}

/** 世界里由语音生成的 SDF 物件（spec 结构见 sdf_prop.ts；tile 为客户端落位后回报）。 */
export interface WorldProp {
  id: string;
  spec: import('./sdf_prop.ts').SdfPropSpec;
  tile: [number, number] | null;
  /** placed=摆在世界（tile 有效）；bagged=收进收集册物品页（tile 置 null）。 */
  state: 'placed' | 'bagged';
  /** 物件所在场景（模型 B）。缺省/undefined = DEFAULT_SCENE（存量物件迁移时补 village）。 */
  sceneId?: string;
}

/**
 * 玩家实体（面向未来 MMO 的一等公民）。
 * 身份来源 = 设备端「开始新游戏」时生成的稳定 UUID（前端存 user://profile.json 并随消息上报）；
 * 本期无任何鉴权流程，未来换设备走 QR + challenge 转移（schema 已就绪，转移流程本期不实现）。
 * 玩家档案原本只在前端本地，MMO 需上服务端——此表把档案结构建好，前端仍可保留本地缓存。
 */
export interface Player {
  id: string;
  name: string;
  nickname: string;
  gender: string; // boy | girl（前端 profile 口径）
  color: string; // 喜欢的颜色名
  spriteAsset: string; // 形象资产 hash（内容寻址，服务端已有）
  createdAt: string; // ISO 时间；由前端 profile 带上，服务端不取墙上时钟
}
// 注：玩家位置不在这里——它按 (world, scene, player) 存 player_positions 表。
// 只按 playerId 存位置在多场景下毫无意义（同一 tile 在不同场景是不同地方）。

/**
 * 一次会话（Visit）：一次「进世界到离开」，作会话结束批量抽记忆的边界（见 design §4）。
 * 身份 = (worldId, playerId, startedAt)，绑世界+玩家而非 socket（兼容未来重连）。
 * endedAt=null 表示进行中（掉线未收尾也可能停留 null，靠 socket.close 兜底置时）。
 */
export interface Visit {
  id: number;
  worldId: string;
  playerId: string;
  startedAt: number;
  endedAt: number | null;
}

/** 记忆分类型（对齐 extractMemory 抽取口径：名字/喜好/约定/发生的事/关系）。 */
export type MemoryKind = 'identity' | 'preference' | 'promise' | 'event' | 'relation';

export const MEMORY_KINDS: readonly MemoryKind[] = ['identity', 'preference', 'promise', 'event', 'relation'];

/**
 * 一条结构化长期记忆（P3：取代 Character.memory: string[]，落 memories 独立表）。
 * 维度 = 「哪个 NPC(owner) 对哪个玩家(aboutPlayer)」的记忆；aboutCharacter 预留 NPC↔NPC（本期主要空）。
 * 旧存量 memory[] 迁移时 aboutPlayer='' 表示「未绑定玩家的历史记忆」，注入时与当前玩家的记忆一起取。
 */
export interface MemoryItem {
  text: string;
  kind: MemoryKind;
  aboutPlayer: string;
  aboutCharacter?: string;
  ts: number;
}

/**
 * extractMemory 的产出：LLM 只决定「记什么内容 + 归哪类」。
 * 归属玩家(aboutPlayer)与时间(ts)由调用方(accumulateMemory)按当前会话补齐——
 * 抽取器不知道当前是哪个玩家，也不读墙上时钟。本期主要产关于玩家的记忆，NPC↔NPC 预留。
 */
export interface ExtractedMemory {
  text: string;
  kind: MemoryKind;
}

// ── 引导式造角色（多轮会话，见 docs/guided-creation-design.md）──────────────

/** 引导式创造累积的属性（幼儿逐轮填；traits 可多个）。造角色/造物共用此结构，各取所需字段。 */
export interface CreationAttrs {
  kind?: string;        // 类型：造角色=猫/狗/龙…；造物=花/风车/小房子…
  color?: string;       // 颜色
  size?: string;        // 大小
  traits: string[];     // 特点：会飞/毛茸茸/发光…（造角色用）
  personality?: string; // 性格（造角色用）
  name?: string;        // 名字（造角色用；语音说，无图标）
  motion?: string;      // 会不会动：安静/会转/会飘/会跳（造物用，映射 SDF locomotion/spin）
}

/** 引导式创造的目标：造新角色 or 造新物件。会话状态机据此分派 guide 与生成接口。 */
export type CreationGoal = 'character' | 'prop';

/** 引导式创造会话状态：连接级（一个孩子一条连接），挂在 VoiceSession 上。 */
export interface CreationState {
  active: boolean;
  goal: CreationGoal;        // 这次会话在造什么（缺省 character，兼容存量调用点）
  attrs: CreationAttrs;
  askedCategories: string[]; // 已问过的类别，避免重复问
  turnCount: number;         // 兜底：超上限强制造
}

/** 引导式创造的属性类别（图标库按此组织；name 无图标走语音，motion 是造物专属）。 */
export type CreationCategory = 'kind' | 'color' | 'size' | 'trait' | 'personality' | 'name' | 'motion';

/** 图标库里的一个候选项。iconAsset 由 P3 图标生成填入（/assets/:hash），未生成为空串。 */
export interface CreationOption {
  id: string;
  category: CreationCategory;
  label: string;
  iconAsset: string;
}

/** guideCreation 一轮的产物：要么继续追问（question+options），要么攒够去造（done+description）。 */
export interface GuideCreationResult {
  replyText: string;                 // 仙子这轮说的话（TTS 念出，含问题与选项口播）
  done: boolean;
  description?: string;              // done：汇总属性给 designCharacter 的中文描述
  question?: string;                // done=false：追问的问题
  category?: CreationCategory;      // done=false：本轮问的类别
  optionIds?: string[];            // done=false：候选项 id（2–4）
  updatedAttrs?: Partial<CreationAttrs>; // 从本轮输入解析出的属性更新（含 traits 增量）
}

/** 引导式创造会话的初始空状态（缺省造角色，兼容存量调用点）。 */
export function newCreationState(goal: CreationGoal = 'character'): CreationState {
  return { active: true, goal, attrs: { traits: [] }, askedCategories: [], turnCount: 0 };
}
