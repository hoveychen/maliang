import type {
  CharacterSpec,
  CreationState,
  ExtractedMemory,
  GuideCreationResult,
  IntentContext,
  IntentResult,
  MemoryExtractionContext,
  ModerationResult,
} from '../types.ts';
import type { SdfPropSpec } from '../sdf_prop.ts';

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
  /** 对话后让角色「自己挑出值得长期记住的要点」（0~3 条，各带分类 kind；去重、归属玩家由 voice 落地）。 */
  extractMemory(ctx: MemoryExtractionContext): Promise<ExtractedMemory[]>;
  /** onboarding 自我介绍：从小朋友的转写里提取名字与称呼（提取不到均返回空串）。 */
  extractProfile(transcript: string): Promise<{ name: string; nickname: string }>;
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

/** 语音识别：音频 → 中文文字。真实实现接讯飞。 */
/** 流式识别会话：录音中持续 feed 分片（实时发往讯飞），finish 收尾并返回最终转写。 */
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
  asr: ASRAdapter;
  tts: TTSAdapter;
  moderation: ModerationAdapter;
}
