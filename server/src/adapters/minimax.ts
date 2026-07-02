// MiniMax 语音合成（t2a_v2）：专用 TTS 引擎，照稿念无 LLM 加戏风险。
// 实测（2026-07，speech-2.6-turbo）：整句 1.0-1.9s，24kHz PCM，30 字 ≈ 67 计费字符 ≈ ¥0.013/条。
import type { TTSAdapter, AudioBlob } from './types.ts';

const ENDPOINT = 'https://api.minimaxi.com/v1/t2a_v2';
// 官方系统音色（部分）：lovely_girl 萌萌女童 / cute_boy 可爱男童 / clever_boy 聪明男童 /
// cartoon_pig 卡通猪小琪 / female-tianmei 甜美女声。角色 voiceId 命中则直用，否则回落默认。
const KNOWN_VOICES = new Set([
  'lovely_girl', 'cute_boy', 'clever_boy', 'cartoon_pig', 'female-tianmei',
]);

export interface MinimaxTTSOptions {
  apiKey: string;
  model?: string;
  /** 角色 voiceId 不认识时的默认音色。 */
  defaultVoice?: string;
  /** 注入点：测试用假 fetch。 */
  fetchFn?: typeof fetch;
}

export function resolveMinimaxVoice(voiceId: string, fallback: string): string {
  return KNOWN_VOICES.has(voiceId) ? voiceId : fallback;
}

export class MinimaxTTSAdapter implements TTSAdapter {
  readonly #apiKey: string;
  readonly #model: string;
  readonly #defaultVoice: string;
  readonly #fetch: typeof fetch;

  constructor(opts: MinimaxTTSOptions) {
    this.#apiKey = opts.apiKey;
    this.#model = opts.model ?? 'speech-2.6-turbo';
    this.#defaultVoice = opts.defaultVoice ?? 'lovely_girl';
    this.#fetch = opts.fetchFn ?? fetch;
  }

  async synthesize(text: string, voiceId: string): Promise<AudioBlob> {
    const res = await this.#fetch(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.#apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: this.#model,
        text,
        voice_setting: { voice_id: resolveMinimaxVoice(voiceId, this.#defaultVoice), speed: 1.0 },
        audio_setting: { sample_rate: 24000, format: 'pcm', channel: 1 },
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) throw new Error(`minimax tts http ${res.status}`);
    const d: any = await res.json();
    if (d?.base_resp?.status_code !== 0 || !d?.data?.audio) {
      throw new Error(`minimax tts ${d?.base_resp?.status_code} ${d?.base_resp?.status_msg ?? 'no audio'}`);
    }
    return {
      bytes: new Uint8Array(Buffer.from(d.data.audio, 'hex')), // 音频以 hex 字符串返回
      mime: 'audio/L16;rate=24000',
    };
  }
}

/** 主 TTS 失败时回落备用（如 minimax 网络故障 → 本地 Kokoro），保证幼儿园现场不哑巴。 */
export class FallbackTTSAdapter implements TTSAdapter {
  readonly #primary: TTSAdapter;
  readonly #secondary: TTSAdapter;

  constructor(primary: TTSAdapter, secondary: TTSAdapter) {
    this.#primary = primary;
    this.#secondary = secondary;
  }

  async synthesize(text: string, voiceId: string): Promise<AudioBlob> {
    try {
      return await this.#primary.synthesize(text, voiceId);
    } catch (err) {
      console.warn(`主 TTS 失败，回落备用：${String(err)}`);
      return this.#secondary.synthesize(text, voiceId);
    }
  }
}
