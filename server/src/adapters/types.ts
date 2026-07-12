import type {
  CharacterSpec,
  CreationState,
  ExtractedMemory,
  GuideCreationResult,
  IntentContext,
  IntentResult,
  MemoryExtractionContext,
  ModerationResult,
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

/** LLM：造角色 spec / 意图路由 / 角色对话。真实实现接 OpenRouter。 */
export interface LLMAdapter {
  designCharacter(intentText: string, byFairy: boolean): Promise<CharacterSpec>;
  /** 按小朋友的描述设计一只 SDF 可动物件/建筑（走路小屋、蹦蹦邮筒…），产物必须过 validateSdfPropSpec。 */
  designSdfProp(intentText: string): Promise<SdfPropSpec>;
  routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult>;
  /** 引导式造角色一轮：给累积状态 + 本轮输入（幼儿点的选项 label 或说的话），返回继续追问或攒够去造。 */
  guideCreation(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /** 引导式造物品一轮：与 guideCreation 平行，问的是 kind/color/size/motion，产物描述喂 designSdfProp。 */
  guideProp(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /** 引导式造贴纸一轮：与 guideProp 平行，问的是 kind(图案)/color，产物描述喂 designSticker。 */
  guideSticker(state: CreationState, childInput: string): Promise<GuideCreationResult>;
  /** 按贴纸的中文描述给出贴纸中文名 + 英文扁平贴纸生图 prompt（喂 generateIconAsset 管线）。 */
  designSticker(intentText: string): Promise<{ name: string; prompt: string }>;
  /** 对话后让角色「自己挑出值得长期记住的要点」（0~3 条，各带分类 kind；去重、归属玩家由 voice 落地）。 */
  extractMemory(ctx: MemoryExtractionContext): Promise<ExtractedMemory[]>;
  /** session 超长压缩：把较旧轮次（并入上次摘要）压成一段中文摘要，session 内继续对话时注入。 */
  compactSession(ctx: SessionCompactionContext): Promise<string>;
  /** onboarding 自我介绍：从小朋友的转写里提取名字与称呼（提取不到均返回空串）。 */
  extractProfile(transcript: string): Promise<{ name: string; nickname: string }>;
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
  generateIdleAnimation(sprite: ImageBlob): Promise<VideoBlob>;
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

/** 语音识别：音频 → 中文文字。真实实现走 sherpa-onnx（LocalASRAdapter）。 */
/** 流式识别会话：录音中持续 feed 分片（实时喂本地 sherpa 识别器），finish 收尾并返回最终转写。 */
export interface ASRStream {
  feed(chunk: Uint8Array): void;
  finish(): Promise<string>;
}

export interface ASRAdapter {
  transcribe(audio: AudioBlob): Promise<string>;
  /** 边说边识别：voice_start 时开流，分片随到随发，voice_end 调 finish 拿转写。 */
  openStream(): ASRStream;
}

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
  asr: ASRAdapter;
  tts: TTSAdapter;
  moderation: ModerationAdapter;
}
