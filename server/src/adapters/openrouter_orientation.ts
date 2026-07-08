import type { ImageBlob, OrientationAdapter, SpriteFacing } from './types.ts';
import type { OpenRouterClient } from './openrouter_client.ts';

/**
 * 立绘朝向检测（OpenRouter vision 模型看图回答）。
 * 只让模型输出单词 LEFT/RIGHT/FRONT，解析按整词匹配；
 * 任何网络/解析失败一律回 'unknown'——保险丝坏了不能拦住主管线。
 */
const PROMPT =
  'Look at this cartoon character sprite. Which horizontal direction is the character\'s ' +
  'body and face mostly pointing, from the viewer\'s perspective? ' +
  'Answer with exactly one word: LEFT, RIGHT, or FRONT (FRONT = facing the viewer head-on, ' +
  'no clear left/right lean).';

export class OpenRouterOrientationAdapter implements OrientationAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;

  constructor(client: OpenRouterClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async detectFacing(image: ImageBlob): Promise<SpriteFacing> {
    try {
      const answer = await this.#client.chatVision(this.#model, PROMPT, image);
      return parseFacing(answer);
    } catch (err) {
      console.warn(`朝向检测失败（放行）: ${err instanceof Error ? err.message : err}`);
      return 'unknown';
    }
  }
}

/** 从模型回答里解析朝向（整词匹配，容忍大小写与围绕的标点/解释文字）。 */
export function parseFacing(answer: string): SpriteFacing {
  const m = /\b(left|right|front)\b/i.exec(answer);
  if (!m) return 'unknown';
  return m[1]!.toLowerCase() as SpriteFacing;
}
