// MiniMax 语音合成（t2a_v2）：专用 TTS 引擎，照稿念无 LLM 加戏风险。
// 实测（2026-07，speech-2.6-turbo）：整句 1.0-1.9s；SSE 流式首包 ~720ms；
// 24kHz PCM，30 字 ≈ 67 计费字符 ≈ ¥0.013/条。
import type { TTSAdapter, TTSStreamCallbacks, AudioBlob } from './types.ts';

const ENDPOINT = 'https://api.minimaxi.com/v1/t2a_v2';
const MIME = 'audio/L16;rate=24000';
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
  /** 语速倍率（0.5-2）。lovely_girl 等童声音色原生 ~3.4 字/s 偏慢，Boss 试听选定 1.35。 */
  speed?: number;
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
  readonly #speed: number;
  readonly #fetch: typeof fetch;

  constructor(opts: MinimaxTTSOptions) {
    this.#apiKey = opts.apiKey;
    this.#model = opts.model ?? 'speech-2.6-turbo';
    this.#defaultVoice = opts.defaultVoice ?? 'lovely_girl';
    this.#speed = opts.speed ?? 1.35;
    this.#fetch = opts.fetchFn ?? fetch;
  }

  #request(text: string, voiceId: string, stream: boolean): Promise<Response> {
    return this.#fetch(ENDPOINT, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.#apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: this.#model,
        text,
        ...(stream ? { stream: true } : {}),
        voice_setting: { voice_id: resolveMinimaxVoice(voiceId, this.#defaultVoice), speed: this.#speed },
        audio_setting: { sample_rate: 24000, format: 'pcm', channel: 1 },
      }),
      signal: AbortSignal.timeout(30000),
    }) as Promise<Response>;
  }

  async synthesize(text: string, voiceId: string): Promise<AudioBlob> {
    const res = await this.#request(text, voiceId, false);
    if (!res.ok) throw new Error(`minimax tts http ${res.status}`);
    const d: any = await res.json();
    if (d?.base_resp?.status_code !== 0 || !d?.data?.audio) {
      throw new Error(`minimax tts ${d?.base_resp?.status_code} ${d?.base_resp?.status_msg ?? 'no audio'}`);
    }
    return {
      bytes: new Uint8Array(Buffer.from(d.data.audio, 'hex')), // 音频以 hex 字符串返回
      mime: MIME,
    };
  }

  /**
   * SSE 流式合成：status=1 分片随到随推 cb.onChunk；status=2 终包是完整音频的重发
   * （实测与中间分片拼接逐字节一致），不推分片、作为返回值供存资产。
   */
  async synthesizeStream(text: string, voiceId: string, cb: TTSStreamCallbacks): Promise<AudioBlob> {
    const res = await this.#request(text, voiceId, true);
    if (!res.ok || !res.body) throw new Error(`minimax tts stream http ${res.status}`);
    cb.onStart(MIME);

    const reader = (res.body as any).getReader();
    const dec = new TextDecoder();
    let buf = '';
    let finalAudio: Uint8Array | null = null;
    const mids: Uint8Array[] = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let i: number;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).trim();
        buf = buf.slice(i + 1);
        if (!line.startsWith('data:')) continue;
        let d: any;
        try { d = JSON.parse(line.slice(5)); } catch { continue; }
        if (d?.base_resp?.status_code !== 0) {
          throw new Error(`minimax tts stream ${d?.base_resp?.status_code} ${d?.base_resp?.status_msg}`);
        }
        const hex: string = d?.data?.audio ?? '';
        if (!hex) continue;
        const pcm = new Uint8Array(Buffer.from(hex, 'hex'));
        if (d.data.status === 2) {
          finalAudio = pcm;
        } else {
          mids.push(pcm);
          cb.onChunk(pcm);
        }
      }
    }
    if (!finalAudio) {
      // 异常收尾（无终包）：用中间分片拼接兜底
      if (mids.length === 0) throw new Error('minimax tts stream: 无音频分片');
      finalAudio = new Uint8Array(Buffer.concat(mids));
    }
    return { bytes: finalAudio, mime: MIME };
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

  /**
   * 流式透传：onStart/onChunk 延迟到主适配器首个分片才对外转发——
   * 因此「首个分片前失败」可整体回落备用（一次性整段推出），对调用方仍是流式语义。
   * 首个分片之后失败则只能向上抛（音频已放出去一半，换声源会精神分裂）。
   */
  async synthesizeStream(text: string, voiceId: string, cb: TTSStreamCallbacks): Promise<AudioBlob> {
    let firstChunkSent = false;
    if (typeof this.#primary.synthesizeStream === 'function') {
      try {
        let mime = MIME;
        return await this.#primary.synthesizeStream(text, voiceId, {
          onStart: (m) => { mime = m; }, // 记下 mime，延后到首个分片时再对外 onStart
          onChunk: (pcm) => {
            if (!firstChunkSent) {
              firstChunkSent = true;
              cb.onStart(mime);
            }
            cb.onChunk(pcm);
          },
        });
      } catch (err) {
        if (firstChunkSent) throw err;
        console.warn(`主 TTS 流式失败（未出声），回落备用整段：${String(err)}`);
      }
    }
    const blob = await this.#secondary.synthesize(text, voiceId);
    cb.onStart(blob.mime);
    cb.onChunk(blob.bytes);
    return blob;
  }
}
