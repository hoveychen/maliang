import type { ModerationAdapter, ImageBlob } from './types.ts';
import type { ModerationResult } from '../types.ts';
import { OpenRouterClient } from './openrouter_client.ts';

const TEXT_SYS = `你是幼儿园内容安全审核员。判断内容是否适合幼儿园儿童（3-6岁）。
只输出 JSON：{"allowed": true 或 false, "reason": "简述"}。
出现暴力、血腥、恐怖、惊吓、武器、成人、危险行为、负面诱导等元素 → allowed=false。`;

const IMAGE_PROMPT = `这张图适合幼儿园儿童（3-6岁）看吗？
只输出 JSON：{"allowed": true 或 false, "reason": "简述"}。
出现暴力、血腥、恐怖、惊吓、武器、成人元素 → allowed=false。`;

function stripFences(s: string): string {
  return s.replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
}

// fail-closed：解析失败一律保守拦截（面向幼儿，安全优先）。
function parseVerdict(raw: string): ModerationResult {
  try {
    const o = JSON.parse(stripFences(raw)) as { allowed?: unknown; reason?: unknown };
    return {
      allowed: o.allowed === true,
      reason: typeof o.reason === 'string' ? o.reason : undefined,
    };
  } catch {
    return { allowed: false, reason: '审核结果解析失败（保守拦截）' };
  }
}

/** 真实内容审核：文字走 LLM 判定，图片走视觉模型判定。出错一律 fail-closed。 */
export class OpenRouterModerationAdapter implements ModerationAdapter {
  readonly #client: OpenRouterClient;
  readonly #textModel: string;
  readonly #imageModel: string;

  constructor(client: OpenRouterClient, textModel: string, imageModel: string) {
    this.#client = client;
    this.#textModel = textModel;
    this.#imageModel = imageModel;
  }

  async moderateText(text: string): Promise<ModerationResult> {
    try {
      const content = await this.#client.chatText(
        this.#textModel,
        [
          { role: 'system', content: TEXT_SYS },
          { role: 'user', content: text },
        ],
        { jsonObject: true },
      );
      return parseVerdict(content);
    } catch {
      return { allowed: false, reason: '审核服务异常（保守拦截）' };
    }
  }

  async moderateImage(input: ImageBlob): Promise<ModerationResult> {
    try {
      const url = `data:${input.mime};base64,${Buffer.from(input.bytes).toString('base64')}`;
      const content = await this.#client.chatVision(this.#imageModel, IMAGE_PROMPT, url);
      return parseVerdict(content);
    } catch {
      return { allowed: false, reason: '图片审核异常（保守拦截）' };
    }
  }
}
