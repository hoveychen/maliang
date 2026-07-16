// 本地语音适配器：sherpa-onnx 进程内推理，无外部服务、无密钥。
// - TTS：Kokoro v1.1-zh（82M，103 音色，输出 24kHz PCM16）—— 与 talk-cli 同款模型
// 服务端只做 TTS：语音识别已整条退役，一律在客户端端侧完成（Android 插件 / macOS GDExtension）。
// 模型文件不入库，由 server/scripts/fetch-voice-models.sh 拉取到 VOICE_MODELS_DIR。
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import type { TTSAdapter, AudioBlob } from './types.ts';

// sherpa-onnx-node 是 CJS native addon（加载 ~30MB 动态库），按需 require，
// 避免 mock 模式下白白载入。
const require = createRequire(import.meta.url);

export const TTS_MODEL_DIR = 'kokoro-multi-lang-v1_1';

/** Kokoro TTS 模型目录在即算就绪（factory 的 auto 路由据此选 local）。 */
export function hasLocalVoiceModels(modelsDir: string): boolean {
  return fs.existsSync(path.join(modelsDir, TTS_MODEL_DIR));
}

// Kokoro v1.1-zh 的 sid ↔ 音色名映射（来源：sherpa-onnx 官方文档 kokoro-multi-lang-v1_1 说话人表）。
// zf_* 中文女声（sid 3-57），zm_* 中文男声（sid 58-102）。
const KOKORO_SID: Record<string, number> = {
  af_maple: 0, af_sol: 1, bf_vale: 2,
  zf_001: 3, zf_002: 4, zf_003: 5, zf_004: 6, zf_005: 7, zf_006: 8, zf_007: 9,
  zf_008: 10, zf_017: 11, zf_018: 12, zf_019: 13, zf_021: 14, zf_022: 15, zf_023: 16,
  zf_024: 17, zf_026: 18, zf_027: 19, zf_028: 20, zf_032: 21, zf_036: 22, zf_038: 23,
  zf_039: 24, zf_040: 25, zf_042: 26, zf_043: 27, zf_044: 28, zf_046: 29, zf_047: 30,
  zf_048: 31, zf_049: 32, zf_051: 33, zf_059: 34, zf_060: 35, zf_067: 36, zf_070: 37,
  zf_071: 38, zf_072: 39, zf_073: 40, zf_074: 41, zf_075: 42, zf_076: 43, zf_077: 44,
  zf_078: 45, zf_079: 46, zf_083: 47, zf_084: 48, zf_085: 49, zf_086: 50, zf_087: 51,
  zf_088: 52, zf_090: 53, zf_092: 54, zf_093: 55, zf_094: 56, zf_099: 57,
  zm_009: 58, zm_010: 59, zm_011: 60, zm_012: 61, zm_013: 62, zm_014: 63, zm_015: 64,
  zm_016: 65, zm_020: 66, zm_025: 67, zm_029: 68, zm_030: 69, zm_031: 70, zm_033: 71,
  zm_034: 72, zm_035: 73, zm_037: 74, zm_041: 75, zm_045: 76, zm_050: 77, zm_052: 78,
  zm_053: 79, zm_054: 80, zm_055: 81, zm_056: 82, zm_057: 83, zm_058: 84, zm_061: 85,
  zm_062: 86, zm_063: 87, zm_064: 88, zm_065: 89, zm_066: 90, zm_068: 91, zm_069: 92,
  zm_080: 93, zm_081: 94, zm_082: 95, zm_089: 96, zm_091: 97, zm_095: 98, zm_096: 99,
  zm_097: 100, zm_098: 101, zm_100: 102,
};
const MAX_SID = 102;

/**
 * voiceId → Kokoro sid：支持音色名（zf_001）与数字 sid（"3"）；
 * 游戏内音色（如 'cn-child-default'）不在表内 → 返回 undefined，由调用方回落默认音色。
 */
export function resolveSid(voiceId: string): number | undefined {
  if (voiceId in KOKORO_SID) return KOKORO_SID[voiceId];
  if (/^\d+$/.test(voiceId)) {
    const n = Number(voiceId);
    if (n <= MAX_SID) return n;
  }
  return undefined;
}

/** Float32 [-1,1] → PCM16LE 字节。 */
export function floatToPcm16(samples: Float32Array): Uint8Array {
  const out = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    out[i] = Math.round(s * 32767);
  }
  return new Uint8Array(out.buffer);
}

export interface LocalVoiceOptions {
  modelsDir: string;
  /** 默认音色（名称或 sid 数字串），角色 voiceId 不认识时回落。默认 zf_001（talk-cli 同款）。 */
  defaultVoice?: string;
  numThreads?: number;
}

/** Kokoro v1.1-zh 语音合成：文字 → 24kHz PCM16（mime 带真实采样率，客户端按 mime 解析）。 */
export class LocalTTSAdapter implements TTSAdapter {
  readonly #tts: any;
  readonly #GenerationConfig: any;
  readonly #defaultSid: number;
  #queue: Promise<unknown> = Promise.resolve(); // 串行化合成：不假设 addon 并发安全

  constructor(opts: LocalVoiceOptions) {
    const sherpa = require('sherpa-onnx-node');
    const dir = path.join(opts.modelsDir, TTS_MODEL_DIR);
    this.#tts = new sherpa.OfflineTts({
      model: {
        kokoro: {
          model: path.join(dir, 'model.onnx'),
          voices: path.join(dir, 'voices.bin'),
          tokens: path.join(dir, 'tokens.txt'),
          dataDir: path.join(dir, 'espeak-ng-data'),
          // 顺序与官方示例一致（us-en 在前）。禁设 lang:'zh'——隔离实验证实它让 espeak-ng
          // 对英文/符号抛 "Failed to set eSpeak-ng voice"，异步路径下回调被吞、synthesize 永久挂起。
          lexicon: `${path.join(dir, 'lexicon-us-en.txt')},${path.join(dir, 'lexicon-zh.txt')}`,
        },
        // 实测（M 系 Mac，fp32 模型）：threads 2→4 长句 RTF 0.69→0.45；int8 版反而更慢（0.76+）故用 fp32
        numThreads: opts.numThreads ?? 4,
        provider: 'cpu',
        debug: 0,
      },
      // 中文数字/日期/电话读法规则（模型包自带 fst）
      ruleFsts: ['date-zh.fst', 'number-zh.fst', 'phone-zh.fst']
        .map((f) => path.join(dir, f))
        .join(','),
      maxNumSentences: 1,
    });
    this.#GenerationConfig = sherpa.GenerationConfig;
    this.#defaultSid = resolveSid(opts.defaultVoice ?? 'zf_001') ?? 3;
  }

  synthesize(text: string, voiceId: string): Promise<AudioBlob> {
    const sid = resolveSid(voiceId) ?? this.#defaultSid;
    const run = this.#queue.then(async () => {
      // generateAsync 在 addon 工作线程上推理，不阻塞事件循环。
      // 兜底超时：native 层若吞掉回调（如 G2P 异常），不能让语音会话和串行队列永久挂死。
      const audio = await Promise.race([
        this.#tts.generateAsync({
          text,
          enableExternalBuffer: true,
          generationConfig: new this.#GenerationConfig({ sid, speed: 1.0 }),
        }),
        new Promise<never>((_, rej) => {
          const t = setTimeout(() => rej(new Error('local tts timeout (30s)')), 30000);
          t.unref?.();
        }),
      ]);
      return {
        bytes: floatToPcm16(audio.samples),
        mime: `audio/L16;rate=${audio.sampleRate}`,
      } satisfies AudioBlob;
    });
    this.#queue = run.catch(() => {}); // 失败不阻断后续合成
    return run;
  }
}

