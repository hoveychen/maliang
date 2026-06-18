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
  error?: { message?: string; code?: number };
}

export class OpenRouterClient {
  readonly #apiKey: string;

  constructor(apiKey: string) {
    this.#apiKey = apiKey;
  }

  async #post(body: Record<string, unknown>): Promise<ChatResponse> {
    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${this.#apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://maliang.game',
        'X-Title': 'maliang',
      },
      body: JSON.stringify(body),
    });
    const json = (await res.json()) as ChatResponse;
    if (!res.ok || json.error) {
      throw new Error(`OpenRouter ${res.status}: ${json.error?.message ?? 'unknown error'}`);
    }
    return json;
  }

  /** 文本对话，返回 message.content。 */
  async chatText(
    model: string,
    messages: ChatMessage[],
    opts: { jsonObject?: boolean } = {},
  ): Promise<string> {
    const body: Record<string, unknown> = { model, messages };
    if (opts.jsonObject) body.response_format = { type: 'json_object' };
    const json = await this.#post(body);
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
