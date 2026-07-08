import { PNG } from 'pngjs';
import type { ImageBlob, VideoAdapter, VideoBlob } from './types.ts';

// 标准 chroma 绿（广播抠像绿），与 ChromaKeyCutoutAdapter 的 isGreen 判定一致。
const CHROMA_GREEN: [number, number, number] = [0, 177, 64];
const TARGET_ASPECT = 16 / 9;

const VIDEOS_ENDPOINT = 'https://openrouter.ai/api/v1/videos';

// 通用 idle 提示：不含具体角色词（任意立绘复用），锁死原地+纯绿背景+首尾闭合。
const IDLE_PROMPT =
  'The character does a gentle idle animation: subtle breathing, slight up-and-down bobbing, ' +
  'small calm idle motion. Camera is completely static, no position drift, the character stays ' +
  'perfectly centered. The background MUST stay a perfectly flat, solid chroma-key green with NO ' +
  'scenery, NO gradient, NO shadow cast on the background. The final frame returns exactly to the ' +
  'starting pose for a seamless, looping animation.';

/**
 * 透明立绘合成到纯 chroma 绿 16:9 画布（居中，alpha over green）。
 * AIGC 视频不带 alpha，故先铺绿；生成后再逐帧抠绿还原透明（见 sprite_sheet.ts）。
 * 导出供单测直接验证（无网络）。
 */
export function compositeOnGreen(sprite: ImageBlob): ImageBlob {
  const src = PNG.sync.read(Buffer.from(sprite.bytes));
  const sw = src.width;
  const sh = src.height;

  // 包住立绘的最小 16:9 画布
  let cw: number;
  let ch: number;
  if (sw / sh < TARGET_ASPECT) {
    ch = sh;
    cw = Math.ceil(sh * TARGET_ASPECT);
  } else {
    cw = sw;
    ch = Math.ceil(sw / TARGET_ASPECT);
  }
  const ox = ((cw - sw) / 2) | 0;
  const oy = ((ch - sh) / 2) | 0;

  const out = new PNG({ width: cw, height: ch });
  const [gr, gg, gb] = CHROMA_GREEN;
  // 全铺绿
  for (let i = 0; i < cw * ch; i++) {
    out.data[i * 4] = gr;
    out.data[i * 4 + 1] = gg;
    out.data[i * 4 + 2] = gb;
    out.data[i * 4 + 3] = 255;
  }
  // 立绘 alpha over green
  for (let y = 0; y < sh; y++) {
    for (let x = 0; x < sw; x++) {
      const si = (y * sw + x) * 4;
      const a = src.data[si + 3]! / 255;
      if (a === 0) continue;
      const di = ((y + oy) * cw + (x + ox)) * 4;
      out.data[di] = Math.round(src.data[si]! * a + gr * (1 - a));
      out.data[di + 1] = Math.round(src.data[si + 1]! * a + gg * (1 - a));
      out.data[di + 2] = Math.round(src.data[si + 2]! * a + gb * (1 - a));
      out.data[di + 3] = 255;
    }
  }
  return { bytes: new Uint8Array(PNG.sync.write(out)), mime: 'image/png' };
}

interface VideoJob {
  status?: string;
  polling_url?: string;
  unsigned_urls?: string[];
  error?: { message?: string } | string;
  usage?: { cost?: number };
}

export interface VideoAdapterOptions {
  /** 默认 bytedance/seedance-1-5-pro（实测最便宜且首尾闭合可用）。 */
  model: string;
  /** 默认 480p（游戏小角色够用，Seedance 地板价）。 */
  resolution?: string;
  /** 默认 4（Seedance 最短时长）。 */
  duration?: number;
  /** 轮询间隔，默认 15s。 */
  pollIntervalMs?: number;
  /** 最长等待，默认 10min（超时抛错，由上层放弃动画、保留静态立绘）。 */
  maxWaitMs?: number;
}

/**
 * OpenRouter 视频生成（Seedance）：透明立绘 → idle 循环绿幕 mp4。
 * /api/v1/videos 是异步端点：submit → poll → download，与 chat/completions 不同，故自带 HTTP。
 * 关键：同一张绿幕图同时当 first_frame + last_frame → 视频回到起点 → 天然无缝闭合。
 */
export class OpenRouterVideoAdapter implements VideoAdapter {
  readonly #apiKey: string;
  readonly #model: string;
  readonly #resolution: string;
  readonly #duration: number;
  readonly #pollIntervalMs: number;
  readonly #maxWaitMs: number;

  constructor(apiKey: string, opts: VideoAdapterOptions) {
    this.#apiKey = apiKey;
    this.#model = opts.model;
    this.#resolution = opts.resolution ?? '480p';
    this.#duration = opts.duration ?? 4;
    this.#pollIntervalMs = opts.pollIntervalMs ?? 15000;
    this.#maxWaitMs = opts.maxWaitMs ?? 10 * 60 * 1000;
  }

  async generateIdleAnimation(sprite: ImageBlob): Promise<VideoBlob> {
    const green = compositeOnGreen(sprite);
    const dataUri = `data:image/png;base64,${Buffer.from(green.bytes).toString('base64')}`;

    const submitted = await this.#json(VIDEOS_ENDPOINT, {
      method: 'POST',
      body: JSON.stringify({
        model: this.#model,
        prompt: IDLE_PROMPT,
        duration: this.#duration,
        resolution: this.#resolution,
        aspect_ratio: '16:9',
        // Seedance 2.0 默认想生成音频会被音频审核拦；统一关掉（1.5 Pro 无音频也无害）。
        generate_audio: false,
        frame_images: [
          { type: 'image_url', image_url: { url: dataUri }, frame_type: 'first_frame' },
          { type: 'image_url', image_url: { url: dataUri }, frame_type: 'last_frame' },
        ],
      }),
    });
    const pollUrl = submitted.polling_url;
    if (!pollUrl) throw new Error(`video submit failed: ${errText(submitted)}`);

    const deadline = Date.now() + this.#maxWaitMs;
    let job = submitted;
    while (job.status !== 'completed') {
      if (job.status === 'failed' || job.status === 'cancelled' || job.status === 'expired') {
        throw new Error(`video ${job.status}: ${errText(job)}`);
      }
      if (Date.now() > deadline) throw new Error('video generation timed out');
      await sleep(this.#pollIntervalMs);
      job = await this.#json(pollUrl, { method: 'GET' });
    }

    const url = job.unsigned_urls?.[0];
    if (!url) throw new Error('video completed but no output url');
    const res = await fetch(url, { headers: { Authorization: `Bearer ${this.#apiKey}` } });
    if (!res.ok) throw new Error(`video download failed: ${res.status}`);
    const bytes = new Uint8Array(await res.arrayBuffer());
    return { bytes, mime: 'video/mp4' };
  }

  async #json(url: string, init: { method: string; body?: string }): Promise<VideoJob> {
    const res = await fetch(url, {
      method: init.method,
      headers: {
        Authorization: `Bearer ${this.#apiKey}`,
        'Content-Type': 'application/json',
        'HTTP-Referer': 'https://maliang.game',
        'X-Title': 'maliang',
      },
      body: init.body,
    });
    const json = (await res.json()) as VideoJob;
    if (!res.ok && !json.status) throw new Error(`OpenRouter videos ${res.status}: ${errText(json)}`);
    return json;
  }
}

function errText(job: VideoJob): string {
  if (typeof job.error === 'string') return job.error;
  return job.error?.message ?? 'unknown error';
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
