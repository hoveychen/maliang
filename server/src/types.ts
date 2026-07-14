// maliang 后端核心类型与造角色协议。客户端是 GDScript，不共享代码，
// 但 WS/REST 协议字段以本文件为准（见 docs/tech-design.md §5.1、§6）。
import type { CreatureSize } from './creation_options.ts';

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

/**
 * 引导精灵的名字（见 docs/fairy-persona-design.md）。
 *
 * 她是神笔的笔灵：画什么什么就活过来，一笔落下就是一个点——所以叫「点点」。
 * 此前三个称呼并存且全是物种不是名字：数据里 name='小神仙'、台词里自称「小仙子」、注释里写「仙女」。
 * 单一来源在此，别再往代码里写字面量。
 */
export const FAIRY_NAME = '点点';

/**
 * 点点的人设。会注入 routeIntent 的 system prompt（作为 ctx.personality）。
 *
 * 只写「她是谁、她想要什么」——**禁止清单（不吐槽/不反讽/不替孩子做决定）刻意不写在这里**，
 * 那是给 LLM 的行为约束，归 system prompt 的静态前缀管（openrouter_llm.ts 的 staticSystem）。
 * 约束混进人设，LLM 会把它当性格念出来。
 */
export const FAIRY_PERSONALITY =
  `神笔的笔灵${FAIRY_NAME}。她说话用第三人称自称「${FAIRY_NAME}」。她不会走路，只会飞——笔没有腿。` +
  '她画什么什么就活过来，最爱显摆手艺，画完一定要问「好看吗」；画歪了就笑自己手笨笨的。' +
  '她怕水，沾了水身上的墨会化开，过水边会紧张地飞高一点。' +
  '她对小朋友做的任何事都夸张地惊叹。她只提议，从不替小朋友做决定。';

/** 所有村民共有的基础交互能力（与 scripts/behavior_executor.gd 的指令集对齐）。
 * 存量角色 abilities 里可能只有旧的两项，意图 prompt 按「基础集 ∪ 角色自带」取并集，免数据迁移。 */
export const BASE_ABILITIES = ['move_to', 'follow', 'stop_follow', 'do_action', 'chat_with', 'deliver_message'];

/** 要「走过去」才能兑现的能力（stop_follow 只有在能 follow 时才有意义，一并算入）。 */
export const LOCOMOTION_ABILITIES = ['move_to', 'follow', 'stop_follow', 'chat_with', 'deliver_message'];

/**
 * 引路（guide_to/guide_stop）—— 小仙子专属，见 docs/fairy-guide-design.md。
 *
 * 刻意**不**放进 LOCOMOTION_ABILITIES：那一组是「她走不了、给了也兑现不了」的能力，会被 effectiveAbilities
 * 从她的 prompt 里剔掉。引路恰恰相反——它是她唯一能兑现的位移，因为走路的是**小朋友**：她只在前面飞、
 * 回头等（客户端 _fairy_guide 状态机），不碰 BehaviorExecutor，故不受那三层封锁的影响。
 */
export const GUIDE_ABILITIES = ['guide_to', 'guide_stop'];

/** 跨场景引路的跳数上限（老板 2026-07-13 拍板）：3-5 岁小朋友扛不住 3-4 跳 portal 的长途跋涉。 */
export const MAX_GUIDE_LEGS = 2;

/** 引路的一跳：在 sceneId 里把小朋友带到 portalTile，他自己走进去即到 toScene（既有 _step_portal 触发）。 */
export interface GuideLeg {
  sceneId: string;
  portalTile: TilePos;
  toScene: string;
}

/** 引路计划：服务端算好「去哪、怎么走」，客户端的引路状态机照着领路。 */
export interface GuidePlan {
  /** 找人还是找地方——决定到达时的收尾（找人：让他打招呼；找地方：仙子说「到啦」）。 */
  targetKind: 'character' | 'location';
  targetName: string;
  targetScene: string;
  /** character 的坐标只是**下发时的快照**：村民会自己走动，客户端到场后按名字重解析（不钉住他）。 */
  targetTile: TilePos;
  /** 逐跳 portal；同场景为空数组。长度受 MAX_GUIDE_LEGS 约束。 */
  legs: GuideLeg[];
}

/** 引路候选（喂意图 LLM）：让它知道「小明」是森林里的一个真实角色，而不是编一个出来。 */
export interface GuideTarget {
  name: string;
  kind: 'character' | 'location';
  sceneId: string;
  sceneName: string;
}

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
  /** 收到的爱心数（玩家互动送❤，只增不减、不动小红花——纯情感计数，集邮册展示用）。 */
  hearts: number;
}

/** 集邮盖章款式目录：完成委托时随机挑一款（纯演出，不影响经济）。id 稳定入存档，客户端映射到 AIGC 盖章图（P5）。 */
export const STAMP_STYLES: readonly string[] = ['star', 'smile', 'paw', 'medal', 'heart'];

/** 委托类型：完成判定全部是客户端确定性事件（送达回调/相邻/到点），不靠 LLM 猜。 */
export type TaskType = 'deliver' | 'bring' | 'visit' | 'wish';

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
  /**
   * wish：这个心愿勾的玩法（wishes.ts 的 ability 名，如 create_prop）。
   * 完成判定不走客户端上报——服务端在造物/造角色/玩游戏【成功】的那个代码点自己知道
   * （见 completeWishOnAbility）。村民不会魔法，真正兑现心愿的是小仙子。
   */
  wishAbility?: string;
  /**
   * 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md）：造物类心愿的两段完成。
   * 造出来那一刻不再当场盖章——先让村民走过去用、发现「还差一点」，小朋友调对体型再盖章。
   * 缺省（无这些字段）= 一段完成（老逻辑 / play_game / guide_to 等无体型可调的能力）。
   */
  wishStage?: 'pending' | 'tried'; // pending（缺省）=还没造出来；tried=造出来了、村民试用中差一点
  refineItemRef?: string;          // 造出来那件东西的引用（item id / character id），调整按它匹配
  refineDir?: 'smaller' | 'bigger';// 该往哪调（按造出来的档反推，保证目标档一定够得到）
  refineFromSize?: CreatureSize;   // 造出来时的体型档（判方向调对没的基准）
  refineTries?: number;            // 已调几次；到 REFINE_MAX_TRIES 无条件盖章，绝不无止境挑刺
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

/** 世界正中心 tile：新角色/点点的降生点（客户端首次上报前的占位值）。 */
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
   *   'scifi:<name>'   科幻主题 gltf 场景（Quaternius/Kenney CC0，客户端 SCIFI_NODES 表）
   *   'sdf_res:<name>' 打包内 SDF spec（assets/sdf_props/<name>.json）
   *   'sdf_inline'     spec 字段内联（语音造物）
   *   'sticker:<name>' 贴纸图（assets/stickers/<name>.webp，边缘竖片，docs/sticker-items-design.md）
   */
  renderRef: string;
  /**
   * spec 按 renderRef 分发：
   *   'sdf_inline' → SDF spec（结构见 sdf_prop.ts，语音造物）
   *   'composed:'  → 组合物零件树（结构见 build_blueprints.ts，积木式造物 B1）
   */
  spec?: import('./sdf_prop.ts').SdfPropSpec | import('./build_blueprints.ts').ComposedSpec;
  /** 占地（tile），锚点居中展开（奇数边）；1×1 / 3×3。 */
  footprintW: number;
  footprintH: number;
  /** false = 可穿行纯点缀（草丛），不参与占用。 */
  blocking: boolean;
  /** 允许压在路面上（水井坐镇广场）。 */
  pathOk: boolean;
  /** SDF 物件围绕锚点的游走半径（米），0 = 不动。 */
  wander: number;
  /**
   * 主题软标签（world-themes：'scifi'/'medieval'/'kitchen'…），可多主题共用。
   * 仅供造世界引导按主题过滤候选、admin 分类；渲染/摆放/占用逻辑一律无视。
   * 缺省 = 无标签（草/路/水时代的内置布景不带）。
   */
  themes?: string[];
  /**
   * 挂载面（docs/sticker-items-design.md §1.1）：缺省 'tile'（矩阵 itemRef，存量语义）；
   * 'edge' 只能挂 tile 四条边缘平面（贴纸类薄片），不进占用位图。
   */
  mount?: 'tile' | 'edge';
}

/** tile 是否落在环面世界内（整数且在 [0, GRID_TILES)）。越界/非整数一律拒收，不做 wrap。 */
export function isValidTile(tile: TilePos): boolean {
  const inRange = (v: number) => Number.isInteger(v) && v >= 0 && v < GRID_TILES;
  return inRange(tile.tileX) && inRange(tile.tileY);
}

/** 立绘上的一个归一化锚点（x,y ∈ [0,1]，原点左上，相对 flip/trim 后的最终立绘图片）。 */
export interface AnchorPoint {
  x: number;
  y: number;
}

/**
 * 角色立绘锚点（docs/character-anchors-design.md §1）：贴纸/道具的附着位。
 * source='vision' 表示三点全部由 vision LLM 原生检测通过合法性校验；
 * 任一点降级到固定比例兜底即记 'fallback'。
 */
export interface CharacterAnchors {
  headTop: AnchorPoint;
  handL: AnchorPoint;
  handR: AnchorPoint;
  source: 'vision' | 'fallback';
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
  appearance: { visualDescription: string; spriteAsset: string; scale: number; size?: CreatureSize; anchors?: CharacterAnchors };
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
  /**
   * 身上贴的贴纸（character-anchors §5）：槽位 → 贴纸实体 id（内置贴纸，mount:'edge' 两用）。
   * 贴上=玩家背包扣一份，摘下=回背包；随角色整对象下发（scene_entered/character_spawned）。
   */
  attachments?: Array<{ slot: 'headTop' | 'handL' | 'handR'; itemId: string }>;
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
  recentHistory?: ChatTurn[]; // 当前 session 的对话（WS 路径整段回喂；旧路径为持久历史截尾）
  /** session 超长压缩的产物：更早轮次的中文摘要（有则注入，让角色不忘本段更早聊过的事）。 */
  sessionSummary?: string;
  /** 角色对当前玩家的长期记忆（带分类，注入时按 kind 分组）。 */
  memory?: { text: string; kind: MemoryKind }[];
  /** 世界里的其他角色花名册（不含自己/点点）：让 LLM 能把「小蓝跟我来」「去找小绿聊天」对上真实角色名。 */
  worldCharacters?: { id: string; name: string }[];
  /** 世界地点名清单（客户端 world_info 上报的 POI 名）：move_to 的 location_name 优先归一到这些名字。 */
  locations?: string[];
  /** 可以带小朋友去的人和地方（仅小仙子有 guide_to 时注入）：让 LLM 把「找小明」对上真实角色，别凭空编。 */
  guideTargets?: GuideTarget[];
  /** 进行中的委托（若有）：让角色记得催/答疑，且不再发起新委托。 */
  activeTask?: ActiveTask;
  /** 可发起的委托候选（无进行中委托时服务端生成）：LLM 觉得时机合适就用自己口吻发起并置 offerTask。 */
  taskCandidate?: ActiveTask;
  /**
   * 这个角色当下的心愿背景（wishes.ts 的 WishDef.context）：它刚才可能在旁边自言自语漏过这件事，
   * 小朋友凑上来问的就是它。注入后角色被搭话时能自然接上自己的念想——而不是一脸茫然。
   */
  wishContext?: string;
  /** 稳定的会话缓存键（`world:character:player`）：作 OpenRouter session_id 做 sticky routing，命中 prompt cache。 */
  cacheKey?: string;
}

/** session 超长压缩（compactSession）的上下文：把较旧轮次压成一段中文摘要，session 内继续对话时注入。 */
export interface SessionCompactionContext {
  characterName: string;
  personality: string;
  /** 上一次压缩的摘要（若有）：新摘要要把它并进去，不丢更早的信息。 */
  previousSummary?: string;
  /** 这次要被压缩掉的较旧轮次（时间正序）。 */
  turns: ChatTurn[];
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

/** 语音编排的返回（推给客户端 character_response）。 */
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
  /** create_sticker 意图的贴纸描述：不下发客户端，由 WS 层摘走并异步造贴纸（sticker_pending/item_created 推送）。仅小仙子有此能力。 */
  stickerRequest?: string;
  /** guide_to 意图算出的引路计划：客户端引路状态机据此领路。带不了（目标不存在/太远）时不下发，只留口头回应。仅小仙子。 */
  guide?: GuidePlan;
  /** guide_stop 意图：小朋友说「不去了」→ 取消进行中的引路（客户端另有「停止」气泡入口，双保险）。仅小仙子。 */
  guideStop?: boolean;
  /** play_game 意图的游戏口语描述（「踢球」「老鹰抓小鸡」）：不下发客户端，由 WS 层摘走→LLM 生成剧本→过 typecheck→开演（stage_begin 广播）。仅小仙子有此能力。 */
  gameRequest?: string;
  /** 主动招呼（进对话对方先开口）：transcript 为空且非玩家发起，客户端据此跳过「没听清」提示。 */
  greeting?: boolean;
}

// ── 剧本生成层（realtime-primitives P5 / docs/realtime-game-primitives-design §9）──
// 口语「我们来踢球吧」→ routeIntent 识别 play_game → LLM 照 stage_sdk.d.ts 生成【真 TS】剧本
// → checkScreenplay 过 typecheck（失败带错回喂重生成 1-2 次）→ stripTypeScriptTypes → vm 沙箱开演。

/** 喂给剧本生成 LLM 的上下文：孩子想玩的游戏 + 当前可选的演员（防腐纪律：规则进脚本、原语已在客户端）。 */
export interface ScreenplayGenContext {
  /** 孩子的口语游戏描述，尽量保留原话（「踢球」「老鹰抓小鸡」「捉迷藏」）。 */
  gameDesc: string;
  /** 当前场景里可当演员的村民名字（不含小仙子/玩家）；LLM 的 cast 角色数不得超过这个数量。 */
  villagerNames: string[];
  /** 场上是否有小朋友在玩（有则剧本可用 stage.player）。 */
  hasPlayer: boolean;
}

/**
 * 生成的剧本草案：过了 typecheck 才返回。
 * cast 是【有序角色名】，与 stage_debut 的 PLAY_ROLES 同套路——运行时把它按序映射到真实村民，
 * 并把演员的 name 设成这些角色名，脚本里的 cast('老鹰') 才能对上（坐标/玩法名不写死在脚本）。
 * soccer 这类无需命名演员的玩法 cast 为空数组（只用 stage.player + 球 + region）。
 */
export interface ScreenplayDraft {
  /** 真 TS 剧本源码（异步函数体，全局只有 stage/cast/console，未剥类型）。 */
  code: string;
  /** 有序角色名，映射到真实村民；空数组=不需要命名演员。 */
  cast: string[];
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
  // 贴纸锚点：玩家 anchors 算在设备档案里（服务端够不着），随 world_info.profile 上报存这儿，
  // 再经 presence 转发给同场景其他人——「别人看到的我」的贴纸位（design §5 actors 流转发）。老档缺省。
  anchors?: CharacterAnchors;
}
// 注：玩家位置不在这里——它按 (world, scene, player) 存 player_positions 表。
// 只按 playerId 存位置在多场景下毫无意义（同一 tile 在不同场景是不同地方）。

/**
 * 一次会话（Visit）：一次「进世界到离开」，作会话结束批量抽记忆的边界（见 design §4）。
 * 身份 = (worldId, playerId, startedAt)，绑世界+玩家而非 socket（兼容未来重连）。
 * endedAt=null 表示进行中（掉线未收尾也可能停留 null，靠 socket.close 兜底置时）。
 */
/**
 * 一段会话建立时的设备快照（activity 记录）。前半段服务端被动拿（连接层），
 * 后半段客户端在 world_info.profile.device 里主动上报。字段全可选：旧客户端/直连不带。
 */
export interface DeviceSnapshot {
  ip?: string; // 客户端 IP：反代过来的走 x-forwarded-for 第一段，否则 socket 远端地址
  ua?: string; // User-Agent（Android WebView/HTTP 客户端会带系统与型号片段）
  model?: string; // 机型（Godot OS.get_model_name）
  os?: string; // 系统名（OS.get_name：Android/macOS/Windows/Linux）
  osVersion?: string; // 系统版本（OS.get_version）
  screen?: string; // 屏幕分辨率，如 "2000x1200"
  godot?: string; // 引擎版本（Engine.get_version_info 拼串）
  app?: string; // 客户端应用版本（构建号 / 版本串）
}

export interface Visit {
  id: number;
  worldId: string;
  playerId: string;
  startedAt: number;
  endedAt: number | null;
  /** 会话建立时的设备快照；旧行/未上报为 null。 */
  device?: DeviceSnapshot | null;
}

/** 记忆分类型（对齐 extractMemory 抽取口径：名字/喜好/约定/发生的事/关系；
 *  creation 不走抽取，由造物完成时程序化写入——「帮小朋友造过什么」，支持「帮我造刚才的小动物」）。 */
export type MemoryKind = 'identity' | 'preference' | 'promise' | 'event' | 'relation' | 'creation';

export const MEMORY_KINDS: readonly MemoryKind[] = ['identity', 'preference', 'promise', 'event', 'relation', 'creation'];

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

/**
 * 引导式创造的目标：造新角色 / 造新物件 / 造贴纸 / 积木式拼装（B1）。会话状态机据此分派 guide 与生成接口。
 * 'build' 与 'prop' 共用会话骨架（同一条 session.creation，goal 区分），但走 guideBuild/createBuildAsync。
 */
export type CreationGoal = 'character' | 'prop' | 'sticker' | 'build';

/** 引导式创造会话状态：连接级（一个孩子一条连接），挂在 VoiceSession 上。 */
export interface CreationState {
  active: boolean;
  goal: CreationGoal;        // 这次会话在造什么（缺省 character，兼容存量调用点）
  attrs: CreationAttrs;
  askedCategories: string[]; // 已问过的类别（mock 确定性解析用；LLM 路径靠 dialog 自带上下文）
  turnCount: number;         // 兜底：超上限强制造
  // 本次创造会话的完整对话（child=小朋友的请求/回答，npc=仙子的追问），按标准多轮 messages 回放给
  // guide LLM——上下文完整，再笨的模型也不会重复问已问过的问题、也能看懂「毛毛」是在答名字。
  dialog: ChatTurn[];
  // 仙子最近帮这个小朋友造过的东西（kind='creation' 记忆，开会话时填入）：
  // 注入 guide prompt，支持「帮我造刚才的小动物，但是会飞的」这类指代。
  recentCreations?: string[];
  // goal==='build' 时的积木拼装状态（拼哪副蓝图 + 各槽填了什么）。turnCount/dialog 复用本对象（同一条会话）。
  build?: BuildState;
}

/**
 * 积木式造物（B1，docs/kids-thinking-build-from-parts.md）会话的拼装状态：附在 CreationState 上（goal==='build' 时非空）。
 * 与 CreationState.attrs 并列——造角色/造物累积「属性」，积木拼装累积「哪个槽坐了哪个零件」。
 */
export interface BuildState {
  blueprintId: string;               // 在拼哪副整体蓝图（WholeBlueprint.id）
  filled: Record<string, string>;    // 已填的槽：slotId → partId（坐进骨架的零件）
  askedSlots: string[];              // 已按功能问过的槽（mock 确定性推进；LLM 靠 dialog 自带上下文）
}

/**
 * guideBuild 一轮的产物：要么继续按功能追问某个槽（question+slotId+兼容零件 optionIds），
 * 要么必填槽全满去落成（done），要么小朋友反悔（cancelled）。与 GuideCreationResult 平行。
 */
export interface GuideBuildResult {
  replyText: string;                 // 点点这轮说的话（TTS 念出）
  done: boolean;
  cancelled?: boolean;               // 小朋友说不拼了（「算了/不拼了」）：清会话、绝不落成、不扣花
  question?: string;                 // done=false：按 functionHint 生成的功能问句（铁律：绝不含零件名）
  slotId?: string;                   // done=false：本轮问的是哪个槽（客户端据此点亮发光）
  optionIds?: string[];              // done=false：该槽兼容零件 partId（partsForSlot）
  filled?: { slotId: string; partId: string }; // 从本轮输入解析出的「填了哪个槽哪个零件」增量
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

/** guideCreation 一轮的产物：要么继续追问（question+options），要么攒够去造（done+description），要么小朋友反悔（cancelled）。 */
export interface GuideCreationResult {
  replyText: string;                 // 仙子这轮说的话（TTS 念出，含问题与选项口播）
  done: boolean;
  cancelled?: boolean;               // 小朋友说不造了（「算了/不要了/不想造了」）：清会话、收占位符，绝不开造
  description?: string;              // done：汇总属性给 designCharacter 的中文描述
  question?: string;                // done=false：追问的问题
  category?: CreationCategory;      // done=false：本轮问的类别
  optionIds?: string[];            // done=false：候选项 id（2–4）
  updatedAttrs?: Partial<CreationAttrs>; // 从本轮输入解析出的属性更新（含 traits 增量）
}

/** 引导式创造会话的初始空状态（缺省造角色，兼容存量调用点）。goal==='build' 时须带 blueprintId 初始化拼装状态。 */
export function newCreationState(goal: CreationGoal = 'character', blueprintId?: string): CreationState {
  const state: CreationState = { active: true, goal, attrs: { traits: [] }, askedCategories: [], turnCount: 0, dialog: [] };
  if (goal === 'build' && blueprintId) state.build = { blueprintId, filled: {}, askedSlots: [] };
  return state;
}
