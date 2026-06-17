import type { CharacterSpec, ModerationResult } from '../types.ts';

export interface ImageBlob {
  bytes: Uint8Array;
  mime: string;
}

/** LLM：造角色 spec / 角色对话。真实实现接 Claude API。 */
export interface LLMAdapter {
  designCharacter(intentText: string, byFairy: boolean): Promise<CharacterSpec>;
  respond(prompt: string): Promise<string>;
}

/** 生图：真实实现接 OpenRouter（google/gemini-*-image），输出纯色背景立绘。 */
export interface ImageAdapter {
  generateSprite(visualDescription: string): Promise<ImageBlob>;
}

/** 抠图：纯色（绿幕）背景 → 透明 PNG。真实实现移植 worldlet 的 ChromaKey。 */
export interface CutoutAdapter {
  removeBackground(input: ImageBlob): Promise<ImageBlob>;
}

/** 内容审核：文字 + 图片，面向幼儿强制。 */
export interface ModerationAdapter {
  moderateText(text: string): Promise<ModerationResult>;
  moderateImage(input: ImageBlob): Promise<ModerationResult>;
}

/** 一组可插拔的第三方适配器；mock 与真实实现共用此契约。 */
export interface ServiceAdapters {
  llm: LLMAdapter;
  image: ImageAdapter;
  cutout: CutoutAdapter;
  moderation: ModerationAdapter;
}
