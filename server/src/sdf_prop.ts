// SDF 可动物件 spec：类型 + 服务端校验/归一化。
// 与客户端 scripts/sdf_spec.gd 的 parse 规则一一对应（形状/腿数/基本体预算上限），
// LLM 产物必须过这层才下发——宁可 clamp 修正也不给客户端喂坏数据。

export interface SdfPropSpin {
  rate: number;
  axis?: [number, number, number];
  pivot?: [number, number, number];
}

export interface SdfPropPart {
  shape: 'sphere' | 'capsule' | 'cone' | 'box' | 'torus' | 'bezier';
  pos: [number, number, number];
  rot?: [number, number, number];
  color: number;
  blend?: number;
  group?: 'body' | 'head';
  spin?: SdfPropSpin | number;
  r?: number;
  len?: number;
  r1?: number;
  r2?: number;
  h?: number;
  size?: [number, number, number];
  // torus（环/圈/把手/光环）：R=大半径, r=管半径, arc=弧半角(度,180满环)
  R?: number;
  arc?: number;
  // bezier（弯管：花茎/彩带/尾巴）：r0/r1=起终管半径, fork=端口挖口, b/c=局部控制点(A在原点)
  r0?: number;
  fork?: number;
  b?: [number, number];
  c?: [number, number];
}

export interface SdfPropLocomotion {
  type: 'none' | 'walker' | 'hopper' | 'flyer';
  legs?: number;
  leg_r?: number;
  hip_h?: number;
  stance?: [number, number];
  hop_h?: number;
  rate?: number;
  hover_h?: number;
  wing_r?: number;
  wing_len?: number;
  wing_pos?: [number, number, number];
  speed?: number;
}

export interface SdfPropRope {
  pos: [number, number, number];
  segments: number;
  r: number;
  len: number;
  color: number;
}

export interface SdfPropSpec {
  name: string;
  palette: string[];
  blend: number;
  outline: number;
  parts: SdfPropPart[];
  locomotion: SdfPropLocomotion;
  ropes: SdfPropRope[];
  /**
   * 体型档整体缩放倍率（明显档 小0.7/中1.0/大1.4，见 docs/prop-size-design.md）。
   * 造物不归一（部件是绝对米），故 scale 是乘在 LLM 设计几何上的倍率；客户端构建 prims 时
   * 每部件 pos/r/len/size 统一乘它。缺省 1.0。由 designSdfProp 从 size 经 sizeToScale 填。
   */
  scale: number;
}

export type SdfPropValidation =
  | { ok: true; spec: SdfPropSpec }
  | { ok: false; error: string };

const MAX_PRIMS = 24; // 与 shaders/sdf_field.gdshaderinc 一致
const SHAPES = new Set(['sphere', 'capsule', 'cone', 'box', 'torus', 'bezier']);
const LOCO_TYPES = new Set(['none', 'walker', 'hopper', 'flyer']);
const HEX_COLOR = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

function num(v: unknown, fallback: number, lo: number, hi: number): number {
  const n = typeof v === 'number' && Number.isFinite(v) ? v : fallback;
  return Math.min(hi, Math.max(lo, n));
}

function vec3(v: unknown, lo: number, hi: number): [number, number, number] | null {
  if (!Array.isArray(v) || v.length < 3) return null;
  const out = v.slice(0, 3).map((x) => num(x, NaN, lo, hi));
  if (out.some((x) => Number.isNaN(x))) return null;
  return out as [number, number, number];
}

function vec2(v: unknown, lo: number, hi: number): [number, number] | null {
  if (!Array.isArray(v) || v.length < 2) return null;
  const out = v.slice(0, 2).map((x) => num(x, NaN, lo, hi));
  if (out.some((x) => Number.isNaN(x))) return null;
  return out as [number, number];
}

/** 校验 + clamp 归一化。结构性错误（形状/腿数/预算）拒收，数值越界一律 clamp。 */
export function validateSdfPropSpec(raw: unknown): SdfPropValidation {
  if (typeof raw !== 'object' || raw === null) return { ok: false, error: 'spec 不是对象' };
  const r = raw as Record<string, unknown>;

  const name = typeof r.name === 'string' && r.name.trim() ? r.name.trim().slice(0, 32) : '小玩意';

  if (!Array.isArray(r.palette) || r.palette.length === 0) return { ok: false, error: 'palette 为空' };
  const palette: string[] = [];
  for (const c of r.palette.slice(0, 6)) {
    if (typeof c !== 'string' || !HEX_COLOR.test(c)) return { ok: false, error: `palette 颜色不合法: ${String(c)}` };
    palette.push(c.toLowerCase());
  }

  if (!Array.isArray(r.parts) || r.parts.length === 0) return { ok: false, error: 'parts 为空' };
  if (r.parts.length > 12) return { ok: false, error: `parts 过多: ${r.parts.length}` };
  const parts: SdfPropPart[] = [];
  for (const rawPart of r.parts) {
    if (typeof rawPart !== 'object' || rawPart === null) return { ok: false, error: 'parts 项不是对象' };
    const p = rawPart as Record<string, unknown>;
    const shape = String(p.shape ?? '');
    if (!SHAPES.has(shape)) return { ok: false, error: `未知形状: ${shape}` };
    const pos = vec3(p.pos ?? [0, 0, 0], -5, 5);
    if (!pos) return { ok: false, error: 'parts.pos 不合法' };
    const color = Math.trunc(num(p.color, 0, 0, palette.length - 1));
    const part: SdfPropPart = { shape: shape as SdfPropPart['shape'], pos, color };
    const rot = vec3(p.rot, -360, 360);
    if (rot) part.rot = rot;
    if (typeof p.blend === 'number') part.blend = num(p.blend, 0.2, 0.01, 0.6);
    if (p.group === 'head') part.group = 'head';
    // 旋转件：数字 = 每秒圈数（简写），或 {rate, axis, pivot}；零轴拒收（与客户端一致）
    if (typeof p.spin === 'number') {
      part.spin = num(p.spin, 0.5, -4, 4);
    } else if (typeof p.spin === 'object' && p.spin !== null) {
      const rawSpin = p.spin as Record<string, unknown>;
      const axis = vec3(rawSpin.axis ?? [0, 0, 1], -1, 1);
      if (!axis || Math.hypot(axis[0], axis[1], axis[2]) < 1e-4) {
        return { ok: false, error: 'spin.axis 不合法' };
      }
      const pivot = vec3(rawSpin.pivot ?? p.pos, -5, 5);
      part.spin = {
        rate: num(rawSpin.rate, 0.5, -4, 4),
        axis,
        pivot: pivot ?? pos,
      };
    }
    switch (part.shape) {
      case 'sphere':
        part.r = num(p.r, 0.2, 0.02, 2.5);
        break;
      case 'capsule':
        part.r = num(p.r, 0.15, 0.02, 2.5);
        part.len = num(p.len, 0.4, 0.02, 4);
        break;
      case 'cone':
        part.r1 = num(p.r1, 0.3, 0.02, 2.5);
        part.r2 = num(p.r2, 0.1, 0.02, 2.5);
        part.h = num(p.h, 0.4, 0.02, 4);
        break;
      case 'box': {
        const size = vec3(p.size ?? [0.4, 0.4, 0.4], 0.04, 4);
        if (!size) return { ok: false, error: 'box.size 不合法' };
        part.size = size;
        break;
      }
      case 'torus':
        part.R = num(p.R, 0.4, 0.02, 2.5);
        part.r = num(p.r, 0.12, 0.02, 1.5);
        part.arc = num(p.arc, 180, 1, 180);
        break;
      case 'bezier': {
        part.r0 = num(p.r0, 0.12, 0.02, 1.5);
        part.r1 = num(p.r1, 0.08, 0.02, 1.5);
        part.fork = num(p.fork, 0, 0, 1);
        const b = vec2(p.b ?? [0.3, 0.3], -4, 4);
        const c = vec2(p.c ?? [0.6, 0], -4, 4);
        if (!b || !c) return { ok: false, error: 'bezier b/c 不合法' };
        part.b = b;
        part.c = c;
        break;
      }
    }
    parts.push(part);
  }

  const rawLoco = (typeof r.locomotion === 'object' && r.locomotion !== null ? r.locomotion : {}) as Record<string, unknown>;
  const locoType = String(rawLoco.type ?? 'none');
  if (!LOCO_TYPES.has(locoType)) return { ok: false, error: `未知 locomotion.type: ${locoType}` };
  const legs = Math.trunc(num(rawLoco.legs, 4, 2, 6));
  if (locoType === 'walker' && ![2, 4, 6].includes(legs)) {
    return { ok: false, error: `walker 腿数只支持 2/4/6, 收到 ${legs}` };
  }
  const locomotion: SdfPropLocomotion = { type: locoType as SdfPropLocomotion['type'] };
  if (locoType === 'walker') {
    locomotion.legs = legs;
    locomotion.leg_r = num(rawLoco.leg_r, 0.1, 0.02, 0.4);
    locomotion.hip_h = num(rawLoco.hip_h, 0.6, 0.1, 2);
    const stance = vec3([...(Array.isArray(rawLoco.stance) ? rawLoco.stance : [0.4, 0.35]), 0], 0, 2);
    locomotion.stance = stance ? [stance[0], stance[1]] : [0.4, 0.35];
  } else if (locoType === 'hopper') {
    locomotion.hop_h = num(rawLoco.hop_h, 0.45, 0.1, 1.5);
    locomotion.rate = num(rawLoco.rate, 1.4, 0.3, 4);
  } else if (locoType === 'flyer') {
    locomotion.hover_h = num(rawLoco.hover_h, 1.2, 0.3, 3);
    locomotion.wing_r = num(rawLoco.wing_r, 0.06, 0.02, 0.3);
    locomotion.wing_len = num(rawLoco.wing_len, 0.35, 0.1, 1.5);
    const wp = vec3(rawLoco.wing_pos, -3, 3);
    if (wp) locomotion.wing_pos = wp;
    locomotion.rate = num(rawLoco.rate, 3, 0.5, 6);
  }
  if (locoType !== 'none') locomotion.speed = num(rawLoco.speed, 0.8, 0.1, 2.5);

  const ropes: SdfPropRope[] = [];
  const rawRopes = Array.isArray(r.ropes) ? r.ropes : [];
  if (rawRopes.length > 3) return { ok: false, error: `ropes 过多: ${rawRopes.length}` };
  for (const rawRope of rawRopes) {
    if (typeof rawRope !== 'object' || rawRope === null) return { ok: false, error: 'ropes 项不是对象' };
    const rp = rawRope as Record<string, unknown>;
    const pos = vec3(rp.pos ?? [0, 0.5, 0], -5, 5);
    if (!pos) return { ok: false, error: 'ropes.pos 不合法' };
    ropes.push({
      pos,
      segments: Math.trunc(num(rp.segments, 3, 1, 8)),
      r: num(rp.r, 0.06, 0.02, 0.3),
      len: num(rp.len, 0.2, 0.05, 0.6),
      color: Math.trunc(num(rp.color, 0, 0, palette.length - 1)),
    });
  }

  let prims = parts.length + ropes.reduce((s, x) => s + x.segments, 0);
  if (locoType === 'walker') prims += legs * 2;
  if (locoType === 'flyer') prims += 2;
  if (prims > MAX_PRIMS) return { ok: false, error: `基本体总数 ${prims} 超过上限 ${MAX_PRIMS}` };

  return {
    ok: true,
    spec: {
      name,
      palette,
      blend: num(r.blend, 0.25, 0.05, 0.6),
      outline: num(r.outline, 0.04, 0, 0.12),
      parts,
      locomotion,
      ropes,
      scale: num(r.scale, 1.0, 0.4, 2.0), // 体型档倍率；raw 一般不含（LLM 按中性尺寸设计），默认 1.0
    },
  };
}

/** 兜底 spec：LLM 输出坏掉时给一只确定性的可爱小方块跳跳。 */
export function fallbackSdfPropSpec(name: string): SdfPropSpec {
  return {
    name,
    palette: ['#e8b04b', '#f4ead4'],
    blend: 0.26,
    outline: 0.04,
    parts: [
      { shape: 'box', pos: [0, 0.55, 0], size: [0.7, 0.6, 0.6], color: 0 },
      { shape: 'sphere', pos: [0, 1.0, 0.15], r: 0.2, color: 1, blend: 0.15 },
    ],
    locomotion: { type: 'hopper', hop_h: 0.4, rate: 1.4, speed: 0.8 },
    ropes: [],
    scale: 1.0,
  };
}
