// OpenRouter chat/completions 薄客户端。文本与图像生成都走 chat/completions。

const ENDPOINT = 'https://openrouter.ai/api/v1/chat/completions';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

interface ChatResponse {
  choices?: Array<{
    message?: {
      content?: string;
      images?: Array<{ image_url?: { url?: string }; url?: string }>;
    };
  }>;
  usage?: {
    prompt_tokens?: number;
    // OpenRouter：读缓存量 cached_tokens、写缓存量 cache_write_tokens（非 Anthropic 的 cache_creation_input_tokens）。
    prompt_tokens_details?: { cached_tokens?: number; cache_write_tokens?: number };
  };
  error?: { message?: string; code?: number };
}

export class OpenRouterClient {
  readonly #apiKey: string;
  readonly #timeoutMs: number;

  constructor(apiKey: string, timeoutMs = 25000) {
    this.#apiKey = apiKey;
    this.#timeoutMs = timeoutMs;
  }

  async #post(body: Record<string, unknown>): Promise<ChatResponse> {
    // 关键：给 fetch 加超时。否则 OpenRouter/Kimi 卡住时 await 永不返回，
    // 整条语音回复挂起 → 客户端一直停在「思考中」。超时则拒绝，由上层转成 voice_failed。
    let res: Response;
    try {
      res = await fetch(ENDPOINT, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${this.#apiKey}`,
          'Content-Type': 'application/json',
          'HTTP-Referer': 'https://maliang.game',
          'X-Title': 'maliang',
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(this.#timeoutMs),
      });
    } catch (err) {
      if (err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError')) {
        throw new Error(`OpenRouter timeout after ${this.#timeoutMs}ms`);
      }
      throw err;
    }
    const json = (await res.json()) as ChatResponse;
    if (!res.ok || json.error) {
      throw new Error(`OpenRouter ${res.status}: ${json.error?.message ?? 'unknown error'}`);
    }
    return json;
  }

  /**
   * 文本对话，返回 message.content。
   * opts.cache：请求顶层加 `cache_control:{type:'ephemeral'}`——OpenRouter 托管断点滑动，
   *   显式缓存 provider（Anthropic/Qwen）据此打点；自动缓存 provider（Moonshot/Gemini…）忽略它，
   *   靠 messages 前缀字节稳定命中（故 prompt 已按静态在前/动态在后编排）。
   * opts.sessionId：作 session_id 做 sticky routing，保证同一对话落同一上游 provider（缓存才连续命中）。
   * 命中量记 usage.prompt_tokens_details.cached_tokens；设 MALIANG_LLM_CACHE_DEBUG 打印，便于观测击穿。
   */
  async chatText(
    model: string,
    messages: ChatMessage[],
    opts: { jsonObject?: boolean; cache?: boolean; sessionId?: string } = {},
  ): Promise<string> {
    // kimi-k2.6 默认开启 reasoning，实测使单次调用从 ~1.8s 涨到 ~8s；语音链路两次 LLM 调用
    // （routeIntent + 文字审核）会累计到十几秒。幼儿对话不需要思考链，统一禁用。
    const body: Record<string, unknown> = { model, messages, reasoning: { enabled: false } };
    if (opts.jsonObject) body.response_format = { type: 'json_object' };
    if (opts.cache) body.cache_control = { type: 'ephemeral' };
    if (opts.sessionId) body.session_id = opts.sessionId;
    const json = await this.#post(body);
    if (process.env.MALIANG_LLM_CACHE_DEBUG) {
      const d = json.usage?.prompt_tokens_details;
      console.log(`[llm-cache] prompt=${json.usage?.prompt_tokens ?? '?'} cached=${d?.cached_tokens ?? 0} write=${d?.cache_write_tokens ?? 0} session=${opts.sessionId ?? '-'}`);
    }
    const content = json.choices?.[0]?.message?.content;
    if (!content) throw new Error('OpenRouter: empty content');
    return content;
  }

  /** 看图提问（vision）：文字 + 一张图（data URL 内联），返回 message.content。 */
  async chatVision(
    model: string,
    prompt: string,
    image: { bytes: Uint8Array; mime: string },
  ): Promise<string> {
    const dataUrl = `data:${image.mime};base64,${Buffer.from(image.bytes).toString('base64')}`;
    const json = await this.#post({
      model,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: prompt },
            { type: 'image_url', image_url: { url: dataUrl } },
          ],
        },
      ],
      // 不带 reasoning 字段：gemini-3.5-flash 等强制 reasoning 的模型收到
      // {enabled:false} 会 400 "Reasoning is mandatory"（2026-07-08 实测）。
    });
    const content = json.choices?.[0]?.message?.content;
    if (!content) throw new Error('OpenRouter: empty content');
    return content;
  }

  /** 图像生成，返回首张图的 bytes + mime（从 data URL 解析）。 */
  async chatImage(model: string, prompt: string): Promise<{ bytes: Uint8Array; mime: string }> {
    const json = await this.#post({
      model,
      messages: [{ role: 'user', content: prompt }],
      modalities: ['image', 'text'],
    });
    const images = json.choices?.[0]?.message?.images;
    const url = images?.[0]?.image_url?.url ?? images?.[0]?.url;
    if (!url || !url.startsWith('data:')) throw new Error('OpenRouter: no image returned');
    const mime = url.slice(5, url.indexOf(';'));
    const b64 = url.slice(url.indexOf(',') + 1);
    return { bytes: Uint8Array.from(Buffer.from(b64, 'base64')), mime };
  }
}
