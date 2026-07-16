import { PNG } from 'pngjs';
import type { ClipName, ImageBlob, VideoAdapter, VideoBlob } from './types.ts';

// 标准 chroma 绿（广播抠像绿），与 ChromaKeyCutoutAdapter 的 isGreen 判定一致。
const CHROMA_GREEN: [number, number, number] = [0, 177, 64];
const TARGET_ASPECT = 16 / 9;

const VIDEOS_ENDPOINT = 'https://openrouter.ai/api/v1/videos';

// 三段提示词都不含具体角色词（任意立绘复用）。
//
// 共享约束（SHARED）是三段能共用同一张图集的前提：三段各自生成，但客户端切段时只换帧、
// 不换几何——若某段里角色变大/走出画/镜头推近，三段合流后的并集裁剪盒会被撑大，全部三段
// 的角色都跟着变小，且切段时位置会漂。所以「原地、同尺寸、不推镜」在每段里都得钉死。
const SHARED_CONSTRAINTS =
  'The camera is completely static: no zoom, no pan, no dolly. The character stays perfectly ' +
  'centered, at exactly the same size and screen position as the input image, and never moves ' +
  'out of frame or towards the camera. The character NEVER turns, rotates or spins to face a ' +
  'different direction — it keeps exactly the same facing as the input image the whole time. ' +
  'Its body does NOT slide left or right: the torso centerline stays fixed on the same vertical ' +
  'axis for every frame. The background MUST stay a perfectly flat, solid chroma-key green with ' +
  'NO scenery, NO gradient, NO shadow cast on the background. The final frame returns exactly to ' +
  'the starting pose for a seamless, looping animation.';

// Partial：'moving' 故意没有提示词（见下方注释）。generateClip 拿不到提示词就抛错——
// 真有人把 moving 加回 CLIP_NAMES 却忘了写提示词时，是当场炸而不是拿 idle 的词去生成。
const CLIP_PROMPTS: Partial<Record<ClipName, string>> = {
  idle:
    'The character does a gentle idle animation: subtle breathing, slight up-and-down bobbing, ' +
    'small calm idle motion. ' + SHARED_CONSTRAINTS,
  // ── 这里没有 moving 段，是实测后的决定，不是漏了 ──
  // 2026-07-14 拿舞舞兔真跑 Seedance 两版：
  //   v1「walks in place / does not travel」→ 模型做成原地转身摇摆，魔法棒从右手甩到左手
  //     （角色外观都变了），逐帧中心横向漂 49px ≈ 游戏里 1.1m。
  //   v2 收紧到「正面行走循环 + 抬腿屈膝 + 上下颠 + 禁转身 + 禁横移」→ 只降到 37px（0.87m），
  //     上下只颠 0.21m。走路本该以上下为主，仍然反着。腿在纱裙下压根没迈。
  // 根因多半在角色而非措辞：这批角色是 chibi 造型，腿常被裙子/身体挡住，模型做不出迈步
  // 就自己换个动作。所以走路观感改由客户端程序化合成（world.gd 的 walk_bob 踏步弹跳 +
  // WALK_SWAY_DEG 左右摇摆 + WALK_FLUTTER 下摆飘动）。省下每角色 $0.046 与 1/3 显存。
  // 要重开这段：先把片子跑出来看，别只改措辞就直接全量回填。
  talking:
    'The character is cheerfully talking: the mouth opens and closes with speech, the head nods ' +
    'and tilts a little, and the hands make small friendly gestures near the chest. The feet stay ' +
    'planted on the same spot. ' + SHARED_CONSTRAINTS,
};

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
 * OpenRouter 视频生成（Seedance）：透明立绘 → 某一段的循环绿幕 mp4。
 * /api/v1/videos 是异步端点：submit → poll → download，与 chat/completions 不同，故自带 HTTP。
 * 关键：同一张绿幕图同时当 first_frame + last_frame → 视频回到起点 → 天然无缝闭合。
 * 实际生成的段见 sprite_sheet.ts 的 CLIP_NAMES（当前 idle + talking 两段，各计费一次，
 * 480p/4s 约 $0.046/次）。moving 不生成——走路是客户端程序化的，原因见下方 CLIP_PROMPTS。
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

  async generateClip(sprite: ImageBlob, clip: ClipName): Promise<VideoBlob> {
    const prompt = CLIP_PROMPTS[clip];
    if (!prompt) throw new Error(`没有 ${clip} 段的提示词（该段目前不生成，见 CLIP_PROMPTS 注释）`);
    const green = compositeOnGreen(sprite);
    const dataUri = `data:image/png;base64,${Buffer.from(green.bytes).toString('base64')}`;

    const submitted = await this.#json(VIDEOS_ENDPOINT, {
      method: 'POST',
      body: JSON.stringify({
        model: this.#model,
        prompt,
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
