import type {
  AvatarAttrs,
  AvatarGuideState,
  ChainStep,
  ChatTurn,
  CharacterSpec,
  CreationState,
  ExtractedMemory,
  GuideAvatarResult,
  GuideBuildResult,
  GuideCreationResult,
  IntentContext,
  IntentResult,
  MemoryExtractionContext,
  ModerationResult,
  ScreenplayDraft,
  ScreenplayGenContext,
  SessionCompactionContext,
} from '../types.ts';
import type { SdfPropSpec } from '../sdf_prop.ts';
import type { CreatureSize } from '../creation_options.ts';

export interface ImageBlob {
  bytes: Uint8Array;
  mime: string;
}

export interface AudioBlob {
  bytes: Uint8Array;
  mime: string;
}

export interface VideoBlob {
  bytes: Uint8Array;
  mime: string;
}

/**
 * 角色动画段名。每段一条独立生成的绿幕视频，三段共用一张图集（见 sprite_sheet.ts）。
 * 客户端按角色状态选段，优先级 talking > moving > idle（见 world.gd）。
 */
export type ClipName = 'idle' | 'moving' | 'talking';

/** LLM：造角色 spec / 意图路由 / 角色对话。真实实现接 OpenRouter。 */
export interface LLMAdapter {
  designCharacter(intentText: string, byFairy: boolean): Promise<CharacterSpec>;
  /** 按小朋友的描述设计一只 SDF 可动物件/建筑（走路小屋、蹦蹦邮筒…），产物必须过 validateSdfPropSpec。 */
  designSdfProp(intentText: string): Promise<SdfPropSpec>;
  /** 把一个英文/拼音物件名（存量造物遗留的 snake_case，如 red_mushroom）译成幼儿看得懂的短中文名词。
   *  只用于回填存量造物名（一次性）；已是中文的名字调用方不该传进来。 */
  translateToChineseName(name: string): Promise<string>;
  routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult>;
  /** 引导式造角色一轮：给累积状态 + 本轮输入（幼儿点的选项 label 或说的话），返回继续追问或攒够去造。 */
  guideCreation(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /** 引导式造物品一轮：与 guideCreation 平行，问的是 kind/color/size/motion，产物描述喂 designSdfProp。 */
  guideProp(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /** 引导式造贴纸一轮：与 guideProp 平行，问的是 kind(图案)/color，产物描述喂 designSticker。 */
  guideSticker(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /**
   * 引导式积木拼装一轮（B1，docs/kids-thinking-build-from-parts.md §3.4）：与 guideProp 平行，但
   * 问的是「未填必填槽的功能线索」、答的是「兼容零件」，产物是往骨架填零件（filled 增量）而非属性描述。
   * 铁律：只问功能不给答案，问句绝不出现零件名。读 state.build（blueprintId + 已填槽）。
   */
  guideBuild(state: CreationState, childInput: string): Promise<GuideBuildResult>;
  /** 按贴纸的中文描述给出贴纸中文名 + 英文扁平贴纸生图 prompt（喂 generateIconAsset 管线）。 */
  designSticker(intentText: string): Promise<{ name: string; prompt: string }>;
  /**
   * 角色专属委托链生成（M1，docs/m1-wish-supply-design.md §2.1）：按角色人设出 3-5 步 ChainStep，
   * 围绕同一个小主题递进。只出语义与话术——deliver/bring/visit 不带目标名（发起时现选）。
   * 产物由调用方 validateChainSteps 把关；失败/超时/不合格调用方回退模板链（task_chain.ts）。
   */
  designTaskChain(ctx: { name: string; personality: string }): Promise<ChainStep[]>;
  /**
   * 剧本生成（realtime-primitives P5）：把「我们来踢球吧」这类口语生成一段【真 TS】剧本。
   * 硬 codegen 任务——真实实现用【强模型】+ 对着 stage_sdk.d.ts 过 typecheck，失败带错回喂重生成 1-2 次；
   * 全部尝试都过不了 typecheck 返回 null（调用方走口头兜底，不开演）。防腐纪律见 docs/realtime-game-primitives-design §3。
   */
  generateScreenplay(ctx: ScreenplayGenContext): Promise<ScreenplayDraft | null>;
  /** 对话后让角色「自己挑出值得长期记住的要点」（0~3 条，各带分类 kind；去重、归属玩家由 voice 落地）。 */
  extractMemory(ctx: MemoryExtractionContext): Promise<ExtractedMemory[]>;
  /** session 超长压缩：把较旧轮次（并入上次摘要）压成一段中文摘要，session 内继续对话时注入。 */
  compactSession(ctx: SessionCompactionContext): Promise<string>;
  /** onboarding 自我介绍：从小朋友的转写里提取名字与称呼（提取不到均返回空串）。 */
  extractProfile(transcript: string): Promise<{ name: string; nickname: string }>;
  /**
   * onboarding 形象引导一轮（docs/onboarding-avatar-redesign-design.md §2.2）：与 guideCreation 平行，
   * 问玩家自己的外观（性别/发型/衣服/主色/图案/配饰）。无 cancelled——小朋友不耐烦就 done 用已知属性画。
   */
  guideAvatar(state: AvatarGuideState, childInput: string): Promise<GuideAvatarResult>;
  /**
   * onboarding 形象描述合成（§2.3）：把属性+对话汇成纯外观中文描述，硬规则——双手空着绝不持物、
   * 喜好一律转译为穿戴元素（恐龙→恐龙连帽衫，不是抱恐龙玩偶）、只有这一个孩子无背景无道具。
   */
  describeAvatar(attrs: AvatarAttrs, dialog: ChatTurn[]): Promise<string>;
  /**
   * 照镜子·改一改（§2.4）：把小朋友点名的修改合并进外观描述，未点名的部分保持原意不变；
   * 产物仍受 describeAvatar 同一套硬规则约束。
   */
  refineAvatar(description: string, childRequest: string): Promise<string>;
  /** 存量角色体型回填：从英文 visualDescription 判定体型（small/medium/big），供 /admin/calibrate-size。 */
  classifyCreatureSize(visualDescription: string): Promise<CreatureSize>;
  respond(prompt: string): Promise<string>;
}

/** 生图：真实实现接 OpenRouter（google/gemini-*-image），输出纯色背景立绘。 */
export interface ImageAdapter {
  generateSprite(visualDescription: string): Promise<ImageBlob>;
  /** 造角色图标专用生图：扁平贴纸图标画风（非角色框），见 sprite_style.buildIconPrompt。 */
  generateIcon(visualDescription: string): Promise<ImageBlob>;
}

/** 抠图：纯色（绿幕）背景 → 透明 PNG。 */
export interface CutoutAdapter {
  removeBackground(input: ImageBlob): Promise<ImageBlob>;
}

/**
 * idle 动画视频：透明立绘 → 首尾闭合的 idle 循环视频（绿幕 mp4，待抠帧成图集）。
 * 真实实现接 OpenRouter /api/v1/videos（Seedance）；绿幕合成+首尾帧闭合在实现内。
 * 慢（60~90s），只在造角色后异步补，不进对话闭环。
 */
export interface VideoAdapter {
  /** 立绘 → 某一段的绿幕循环 mp4（首尾闭合）。每段一次调用、一次计费。 */
  generateClip(sprite: ImageBlob, clip: ClipName): Promise<VideoBlob>;
}

/**
 * 立绘朝向。游戏端约定「原图=朝右」（world.gd 向左走时水平镜像），
 * 生图模型对 "facing right" 的服从没有硬保证，所以生成管线要检测兜底。
 * 'bad' = 图本身不可用（多角色三视图/裁切残图），与 'front' 一样走重试。
 */
export type SpriteFacing = 'left' | 'right' | 'front' | 'bad' | 'unknown';

/** 朝向检测：立绘 → 面朝方向。真实实现接 OpenRouter vision；检测失败返回 'unknown'（放行，不阻塞生成）。 */
export interface OrientationAdapter {
  detectFacing(image: ImageBlob): Promise<SpriteFacing>;
}

/** vision LLM 检出的原始锚点（归一化 0-1，未过合法性校验）。 */
export interface RawAnchorPoints {
  headTop: { x: number; y: number };
  handL: { x: number; y: number };
  handR: { x: number; y: number };
}

/**
 * 锚点指点检测（docs/character-anchors-design.md §2）：立绘 → 头顶/双手归一化点位。
 * 检测失败/解析不出返回 null（不 throw）——调用方（anchors.ts）走固定比例兜底，不阻塞主管线。
 * PoC 实证（2026-07-12，12/12）：gemini flash 对非人形（四足/鸟/龙）也能"指哪算哪"。
 */
export interface AnchorAdapter {
  detectAnchors(image: ImageBlob): Promise<RawAnchorPoints | null>;
}

// 语音识别没有服务端适配器：识别一律在客户端端侧完成（Android 插件 / macOS GDExtension 的
// sherpa-onnx），服务端只收 voice_transcript 的成品文本。服务端 ASR 于 2026-07-13 整条退役。

/** 流式合成回调：onStart 在首个分片前带 mime（客户端要先知道采样率），onChunk 按序推 PCM16 分片。 */
export interface TTSStreamCallbacks {
  onStart(mime: string): void;
  onChunk(pcm: Uint8Array): void;
}

/** 语音合成：文字 + 音色 → 音频。 */
export interface TTSAdapter {
  synthesize(text: string, voiceId: string): Promise<AudioBlob>;
  /**
   * 可选流式合成：分片随合成推给 cb，resolve 返回完整音频（与分片拼接一致，供存资产回放）。
   * 首个分片前失败应 throw 且不得调用过 cb.onChunk——调用方以此安全回落非流式路径。
   */
  synthesizeStream?(text: string, voiceId: string, cb: TTSStreamCallbacks): Promise<AudioBlob>;
}

/** 内容审核：文字（图片由生图模型自带安全门把关，不单独审核）。 */
export interface ModerationAdapter {
  moderateText(text: string): Promise<ModerationResult>;
}

/** 一组可插拔的第三方适配器；mock 与真实实现共用此契约。 */
export interface ServiceAdapters {
  llm: LLMAdapter;
  image: ImageAdapter;
  cutout: CutoutAdapter;
  video: VideoAdapter;
  orientation: OrientationAdapter;
  anchors: AnchorAdapter;
  tts: TTSAdapter;
  moderation: ModerationAdapter;
}
