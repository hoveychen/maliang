import type { ImageAdapter, ImageBlob } from './types.ts';
import { OpenRouterClient } from './openrouter_client.ts';
import { buildSpritePrompt } from './sprite_style.ts';

/** 生图：visualDescription（主体）+ 统一画风后缀 喂给 OpenRouter 的 Gemini 图像模型，输出绿底立绘。 */
export class OpenRouterImageAdapter implements ImageAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;

  constructor(client: OpenRouterClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async generateSprite(visualDescription: string): Promise<ImageBlob> {
    return this.#client.chatImage(this.#model, buildSpritePrompt(visualDescription));
  }
}
