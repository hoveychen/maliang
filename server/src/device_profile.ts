/**
 * 设备画质档众包：新机器跑一次 benchmark（贪心搜出能跑稳 30fps 的最高画质档），把结果按
 * GPU 型号上传；后来的同 GPU 机器启动时直接下发，不必再当小白鼠。
 *
 * 为什么 key 只用 GPU（不带机型/散热/系统版本）：命中率优先。市面上 GPU 型号远少于机型，
 * 绝大多数用户（尤其 iPhone，就那几款 GPU）一启动就命中已有结果，全程无感。
 *
 * 为什么服务端不认识旋钮名：旋钮集合定义在客户端（GraphicsSettings.KEYS）。服务端若也硬编码
 * 一份，客户端每加一个旋钮都得同步改服务端，两处早晚漂移。这里只做通用校验（键名格式、值域），
 * 聚合时对样本里出现的键取值——客户端演进不需要动服务端。旋钮集合真的变了就 bump BENCH_VERSION，
 * 旧样本按不同 version 隔离，自然作废。
 */

/** benchmark 口径版本：渲染管线/负载场景/旋钮集合变了就 +1，旧样本自动隔离作废。
 *  必须与 scripts/device_profile.gd 的 BENCH_VERSION 一致。
 *  v2（P5）：压测负载换 seed 村民图集 + 采样期冻结世界，渲染成本口径变了 → 旧 v1 样本作废。 */
export const BENCH_VERSION = 2;

export type Levels = Record<string, number>;

export interface DeviceSample {
  gpu: string;
  benchVersion: number;
  deviceId: string;
  levels: Levels;
  p95Ms: number;
  /** benchmark 结束时是否真的跑到了 30fps（没达标也要存——那是这台机器的真实上限）。 */
  hit: boolean;
}

const KEY_RE = /^[a-z][a-z0-9_]{0,31}$/;
const MAX_KEYS = 32;
const MAX_LEVEL = 8;

/** 规整上传的档位表；任何一项不合法就整份拒收（宁可不收，也不让脏数据污染众包）。 */
export function sanitizeLevels(raw: unknown): Levels | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const entries = Object.entries(raw as Record<string, unknown>);
  if (entries.length === 0 || entries.length > MAX_KEYS) return null;
  const out: Levels = {};
  for (const [k, v] of entries) {
    if (!KEY_RE.test(k)) return null;
    if (typeof v !== 'number' || !Number.isInteger(v) || v < 0 || v > MAX_LEVEL) return null;
    out[k] = v;
  }
  return out;
}

/** GPU 名归一：去掉厂商噪声后缀/多余空白，让 "Adreno (TM) 610" 与 "Adreno(TM)  610" 落同一个桶。 */
export function normalizeGpu(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const s = raw.replace(/\(TM\)|\(R\)|™|®/gi, ' ').replace(/\s+/g, ' ').trim();
  if (s.length === 0 || s.length > 120) return null;
  return s;
}

/** 规整整条上传样本；不合法返回 null（路由据此回 400）。 */
export function sanitizeSample(body: unknown): DeviceSample | null {
  if (!body || typeof body !== 'object') return null;
  const b = body as Record<string, unknown>;
  const gpu = normalizeGpu(b.gpu);
  const levels = sanitizeLevels(b.levels);
  const p95Ms = Number(b.p95Ms);
  const benchVersion = Number(b.benchVersion);
  const deviceId = typeof b.deviceId === 'string' ? b.deviceId.trim() : '';
  if (!gpu || !levels) return null;
  if (!Number.isInteger(benchVersion) || benchVersion < 1) return null;
  if (!Number.isFinite(p95Ms) || p95Ms <= 0 || p95Ms > 10_000) return null;
  if (deviceId.length === 0 || deviceId.length > 64) return null;
  return { gpu, benchVersion, deviceId, levels, p95Ms, hit: b.hit === true };
}

/**
 * 把同一 GPU 的多台设备样本合成一份下发档：逐旋钮取最保守（最低）的那一档。
 *
 * 为什么取最保守而不是多数派/中位数：这是给幼儿园孩子用的——卡顿比画质掉一档伤害大得多。
 * 同型号里只要有一台机器需要关某项才跑得动（散热差、后台进程多），就让所有同型号都关掉它。
 * 代价是一台发烫的机器会拖累同 GPU 的其他人，换来的是没有人会卡。
 */
export function aggregateLevels(samples: Levels[]): Levels | null {
  if (samples.length === 0) return null;
  const out: Levels = {};
  for (const s of samples) {
    for (const [k, v] of Object.entries(s)) {
      out[k] = k in out ? Math.min(out[k], v) : v;
    }
  }
  return out;
}
