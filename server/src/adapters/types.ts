import type {
  CharacterSpec,
  IntentContext,
  IntentResult,
  MemoryExtractionContext,
  ModerationResult,
} from '../types.ts';

export interface ImageBlob {
  bytes: Uint8Array;
  mime: string;
}

export interface AudioBlob {
  bytes: Uint8Array;
  mime: string;
}

/** LLM：造角色 spec / 意图路由 / 角色对话。真实实现接 OpenRouter。 */
export interface LLMAdapter {
  designCharacter(intentText: string, byFairy: boolean): Promise<CharacterSpec>;
  routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult>;
  /** 对话后让角色「自己挑出值得长期记住的要点」（0~3 条简短中文，去重后由 voice 落地）。 */
  extractMemory(ctx: MemoryExtractionContext): Promise<string[]>;
  respond(prompt: string): Promise<string>;
}

/** 生图：真实实现接 OpenRouter（google/gemini-*-image），输出纯色背景立绘。 */
export interface ImageAdapter {
  generateSprite(visualDescription: string): Promise<ImageBlob>;
}

/** 抠图：纯色（绿幕）背景 → 透明 PNG。 */
export interface CutoutAdapter {
  removeBackground(input: ImageBlob): Promise<ImageBlob>;
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
  asr: ASRAdapter;
  tts: TTSAdapter;
  moderation: ModerationAdapter;
}
