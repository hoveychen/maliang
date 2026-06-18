import type { ModerationAdapter } from './types.ts';
import type { ModerationResult } from '../types.ts';
import { OpenRouterClient } from './openrouter_client.ts';

const TEXT_SYS = `你是幼儿园内容安全审核员。判断内容是否适合幼儿园儿童（3-6岁）。
只输出 JSON：{"allowed": true 或 false, "reason": "简述"}。
出现暴力、血腥、恐怖、惊吓、武器、成人、危险行为、负面诱导等元素 → allowed=false。`;

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

/** 真实文字内容审核：LLM 判定，出错一律 fail-closed（拦截）。 */
export class OpenRouterModerationAdapter implements ModerationAdapter {
  readonly #client: OpenRouterClient;
  readonly #textModel: string;

  constructor(client: OpenRouterClient, textModel: string) {
    this.#client = client;
    this.#textModel = textModel;
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
}
