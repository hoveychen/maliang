import crypto from 'node:crypto';
import type { ASRAdapter, ASRStream, TTSAdapter, AudioBlob } from './types.ts';

export interface XfyunCreds {
  appId: string;
  apiKey: string;
  apiSecret: string;
}

// 讯飞 v2 WebSocket 鉴权：HMAC-SHA256 签名拼进 query。
function authUrl(host: string, path: string, creds: XfyunCreds): string {
  const date = new Date().toUTCString();
  const sigOrigin = `host: ${host}\ndate: ${date}\nGET ${path} HTTP/1.1`;
  const sig = crypto.createHmac('sha256', creds.apiSecret).update(sigOrigin).digest('base64');
  const authOrigin = `api_key="${creds.apiKey}", algorithm="hmac-sha256", headers="host date request-line", signature="${sig}"`;
  const authorization = Buffer.from(authOrigin).toString('base64');
  const params = new URLSearchParams({ authorization, date, host });
  return `wss://${host}${path}?${params.toString()}`;
}

const KNOWN_VCN = new Set(['xiaoyan', 'aisjiuxu', 'aisxping', 'aisjinger', 'aisbabyxu']);
// 默认童声：幼儿游戏角色 voiceId 多为 'cn-child-default'（不在已知发音人集合），
// 回落到 aisbabyxu（讯飞童声）而非成人播音腔 xiaoyan。账号已验证 aisbabyxu/aisjinger 可用。
export function resolveVcn(voiceId: string): string {
  return KNOWN_VCN.has(voiceId) ? voiceId : 'aisbabyxu';
}

/** 讯飞在线语音合成：文字 → 16k PCM（audio/L16，客户端可包成 AudioStreamWAV 播放）。 */
export class XfyunTTSAdapter implements TTSAdapter {
  readonly #creds: XfyunCreds;
  constructor(creds: XfyunCreds) {
    this.#creds = creds;
  }

  synthesize(text: string, voiceId: string): Promise<AudioBlob> {
    const creds = this.#creds;
    return new Promise((resolve, reject) => {
      const ws: any = new WebSocket(authUrl('tts-api.xfyun.cn', '/v2/tts', creds));
      const chunks: Buffer[] = [];
      const timer = setTimeout(() => {
        reject(new Error('xfyun tts timeout'));
        try { ws.close(); } catch (_e) { /* ignore */ }
      }, 20000);
      ws.onopen = () => {
        ws.send(JSON.stringify({
          common: { app_id: creds.appId },
          business: { aue: 'raw', auf: 'audio/L16;rate=16000', vcn: resolveVcn(voiceId), tte: 'UTF8', speed: 50, volume: 50, pitch: 50 },
          data: { status: 2, text: Buffer.from(text, 'utf8').toString('base64') },
        }));
      };
      ws.onmessage = (m: any) => {
        const d = JSON.parse(typeof m.data === 'string' ? m.data : m.data.toString());
        if (d.code !== 0) {
          clearTimeout(timer);
          reject(new Error(`xfyun tts ${d.code} ${d.message}`));
          ws.close();
          return;
        }
        if (d.data?.audio) chunks.push(Buffer.from(d.data.audio, 'base64'));
        if (d.data?.status === 2) {
          clearTimeout(timer);
          ws.close();
          resolve({ bytes: new Uint8Array(Buffer.concat(chunks)), mime: 'audio/L16;rate=16000' });
        }
      };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error('xfyun tts ws error'));
      };
    });
  }
}

/** 讯飞语音听写：16k PCM 音频 → 中文文字。 */
export class XfyunASRAdapter implements ASRAdapter {
  readonly #creds: XfyunCreds;
  constructor(creds: XfyunCreds) {
    this.#creds = creds;
  }

  transcribe(audio: AudioBlob): Promise<string> {
    const creds = this.#creds;
    const pcm = Buffer.from(audio.bytes);
    return new Promise((resolve, reject) => {
      const ws: any = new WebSocket(authUrl('iat-api.xfyun.cn', '/v2/iat', creds));
      let text = '';
      const timer = setTimeout(() => {
        reject(new Error('xfyun asr timeout'));
        try { ws.close(); } catch (_e) { /* ignore */ }
      }, 20000);
      ws.onopen = () => {
        // 我们手里已是录好的完整音频，无需按 40ms/帧模拟实时上传。全速发完所有帧，
        // 讯飞接受全速上传且识别不变——实测 ASR 3972ms→1005ms（去节流前后同句一字不差）。
        const frameSize = 1280; // 40ms @ 16k/16bit
        let off = 0;
        let first = true;
        const send = (): void => {
          if (off >= pcm.length) {
            ws.send(JSON.stringify({ data: { status: 2, format: 'audio/L16;rate=16000', encoding: 'raw', audio: '' } }));
            return;
          }
          const chunk = pcm.subarray(off, off + frameSize);
          off += frameSize;
          const msg = first
            ? { common: { app_id: creds.appId }, business: { language: 'zh_cn', domain: 'iat', accent: 'mandarin', vad_eos: 3000 }, data: { status: 0, format: 'audio/L16;rate=16000', encoding: 'raw', audio: chunk.toString('base64') } }
            : { data: { status: 1, format: 'audio/L16;rate=16000', encoding: 'raw', audio: chunk.toString('base64') } };
          first = false;
          ws.send(JSON.stringify(msg));
          send();
        };
        send();
      };
      ws.onmessage = (m: any) => {
        const d = JSON.parse(typeof m.data === 'string' ? m.data : m.data.toString());
        if (d.code !== 0) {
          clearTimeout(timer);
          reject(new Error(`xfyun asr ${d.code} ${d.message}`));
          ws.close();
          return;
        }
        if (d.data?.result) {
          for (const w of d.data.result.ws) for (const c of w.cw) text += c.w;
        }
        if (d.data?.status === 2) {
          clearTimeout(timer);
          ws.close();
          resolve(text);
        }
      };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error('xfyun asr ws error'));
      };
    });
  }

  /** 边说边识别：开流后分片随到随发往讯飞，finish 时发结束帧并返回最终转写。 */
  openStream(): ASRStream {
    const creds = this.#creds;
    const ws: any = new WebSocket(authUrl('iat-api.xfyun.cn', '/v2/iat', creds));
    let text = '';
    let open = false;
    let first = true;
    let finished = false;
    const queue: Uint8Array[] = [];
    let resolveFn: (v: string) => void;
    let rejectFn: (e: Error) => void;
    const result = new Promise<string>((res, rej) => { resolveFn = res; rejectFn = rej; });
    const timer = setTimeout(() => {
      rejectFn(new Error('xfyun asr stream timeout'));
      try { ws.close(); } catch (_e) { /* ignore */ }
    }, 25000);

    const sendChunk = (chunk: Uint8Array): void => {
      const audio = Buffer.from(chunk).toString('base64');
      const msg = first
        ? { common: { app_id: creds.appId }, business: { language: 'zh_cn', domain: 'iat', accent: 'mandarin', vad_eos: 3000 }, data: { status: 0, format: 'audio/L16;rate=16000', encoding: 'raw', audio } }
        : { data: { status: 1, format: 'audio/L16;rate=16000', encoding: 'raw', audio } };
      first = false;
      ws.send(JSON.stringify(msg));
    };
    const sendEnd = (): void => {
      ws.send(JSON.stringify({ data: { status: 2, format: 'audio/L16;rate=16000', encoding: 'raw', audio: '' } }));
    };

    ws.onopen = () => {
      open = true;
      while (queue.length > 0) sendChunk(queue.shift()!); // 连接前积压的分片补发
      if (finished) sendEnd();
    };
    ws.onmessage = (m: any) => {
      const d = JSON.parse(typeof m.data === 'string' ? m.data : m.data.toString());
      if (d.code !== 0) {
        clearTimeout(timer);
        rejectFn(new Error(`xfyun asr ${d.code} ${d.message}`));
        ws.close();
        return;
      }
      if (d.data?.result) for (const w of d.data.result.ws) for (const c of w.cw) text += c.w;
      if (d.data?.status === 2) {
        clearTimeout(timer);
        ws.close();
        resolveFn(text);
      }
    };
    ws.onerror = () => {
      clearTimeout(timer);
      rejectFn(new Error('xfyun asr ws error'));
    };

    return {
      feed(chunk: Uint8Array): void {
        if (open) sendChunk(chunk);
        else queue.push(chunk); // 连接还没建好，先入队，onopen 时补发
      },
      finish(): Promise<string> {
        finished = true;
        if (open) sendEnd(); // 连接已开：分片都已实时发出，这里只补结束帧
        return result; // 未开则 onopen 里补发结束帧
      },
    };
  }
}
