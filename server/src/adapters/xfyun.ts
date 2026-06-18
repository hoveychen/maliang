import crypto from 'node:crypto';
import type { ASRAdapter, TTSAdapter, AudioBlob } from './types.ts';

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
function resolveVcn(voiceId: string): string {
  return KNOWN_VCN.has(voiceId) ? voiceId : 'xiaoyan';
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
          setTimeout(send, 40);
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
}
