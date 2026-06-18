import type { CharacterSpec, IntentContext, IntentResult, ModerationResult } from '../types.ts';

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
export interface ASRAdapter {
  transcribe(audio: AudioBlob): Promise<string>;
}

/** 语音合成：文字 + 音色 → 音频。真实实现接讯飞。 */
export interface TTSAdapter {
  synthesize(text: string, voiceId: string): Promise<AudioBlob>;
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
