/**
 * 角色立绘锚点：vision 检测结果的像素级合法性校验 + alpha 兜底（docs/character-anchors-design.md §2-§3）。
 * 坐标系约定：全部归一化到 flip/trim 之后的最终入库立绘（与客户端拿到的贴图逐像素对应），
 * 所以本模块必须在 orchestrator 的 trimToContent 之后调用。
 * 纯函数 + 一个编排入口 detectCharacterAnchors；vision 失败/校验不过逐点降级，绝不 throw。
 */

import type { ImageBlob } from './adapters/types.ts';
import type { AnchorAdapter, RawAnchorPoints } from './adapters/types.ts';
import { decode, type Raster } from './adapters/chroma_cutout.ts';
import type { AnchorPoint, CharacterAnchors } from './types.ts';

/** 视为不透明的最低 alpha（与 trimToContent 同阈值）。 */
const ALPHA_THRESH = 8;
/** 合法性校验半径：点周围此比例×图宽内必须有不透明像素（防 LLM 点飞到空白处）。 */
const NEAR_RATIO = 0.03;
/** 兜底手部所在高度（身高比例，自顶向下）；PoC 里"身体中腰侧缘"的近似。 */
const FALLBACK_HAND_Y = 0.55;
/** 兜底手部从身体边缘向内收的比例（贴纸中心别悬在轮廓线外）。 */
const FALLBACK_HAND_INSET = 0.05;

function alphaAt(r: Raster, x: number, y: number): number {
  return r.data[(y * r.width + x) * 4 + 3]!;
}

/** 点（归一化）半径内是否存在不透明像素。 */
export function nearOpaque(r: Raster, p: AnchorPoint, ratio = NEAR_RATIO): boolean {
  const rad = Math.max(1, Math.round(r.width * ratio));
  const cx = Math.round(p.x * (r.width - 1));
  const cy = Math.round(p.y * (r.height - 1));
  for (let dy = -rad; dy <= rad; dy++) {
    const y = cy + dy;
    if (y < 0 || y >= r.height) continue;
    for (let dx = -rad; dx <= rad; dx++) {
      const x = cx + dx;
      if (x < 0 || x >= r.width) continue;
      if (alphaAt(r, x, y) >= ALPHA_THRESH) return true;
    }
  }
  return false;
}

/** alpha 头顶兜底：首个不透明行的 y + 自该行向下连吃 3 行的中心 x（抗单像素噪点）。全透明图回图心上沿。 */
export function alphaHeadTop(r: Raster): AnchorPoint {
  for (let y = 0; y < r.height; y++) {
    let rowHit = false;
    for (let x = 0; x < r.width; x++) {
      if (alphaAt(r, x, y) >= ALPHA_THRESH) {
        rowHit = true;
        break;
      }
    }
    if (!rowHit) continue;
    let sum = 0;
    let n = 0;
    for (let yy = y; yy < Math.min(y + 3, r.height); yy++) {
      for (let x = 0; x < r.width; x++) {
        if (alphaAt(r, x, yy) >= ALPHA_THRESH) {
          sum += x;
          n++;
        }
      }
    }
    return { x: sum / n / (r.width - 1), y: y / (r.height - 1) };
  }
  return { x: 0.5, y: 0.02 };
}

/** alpha 手部兜底：身高 55% 行上最左/最右不透明像素，向内收 5% 图宽。行全透明按图宽 1/4、3/4。 */
export function alphaHandFallback(r: Raster, side: 'L' | 'R'): AnchorPoint {
  const y = Math.round(FALLBACK_HAND_Y * (r.height - 1));
  let minX = -1;
  let maxX = -1;
  for (let x = 0; x < r.width; x++) {
    if (alphaAt(r, x, y) >= ALPHA_THRESH) {
      if (minX < 0) minX = x;
      maxX = x;
    }
  }
  if (minX < 0) return { x: side === 'L' ? 0.25 : 0.75, y: FALLBACK_HAND_Y };
  const inset = r.width * FALLBACK_HAND_INSET;
  const px = side === 'L' ? minX + inset : maxX - inset;
  return { x: Math.min(1, Math.max(0, px / (r.width - 1))), y: FALLBACK_HAND_Y };
}

/**
 * vision 原始点 → 合法性校验 → 逐点降级 → CharacterAnchors。
 * 校验规则（设计 §2.2）：每点半径 3% 图宽内有不透明像素；headTop 的 y 须在上半部。
 * raw=null（检测失败）= 三点全兜底。source='vision' 仅当三点全部原生通过。
 */
export function validateAnchors(r: Raster, raw: RawAnchorPoints | null): CharacterAnchors {
  let allNative = raw !== null;
  const pick = (p: { x: number; y: number } | undefined, ok: boolean, fallback: () => AnchorPoint): AnchorPoint => {
    if (p && ok) return { x: p.x, y: p.y };
    allNative = false;
    return fallback();
  };
  const headTop = pick(
    raw?.headTop,
    raw ? raw.headTop.y <= 0.5 && nearOpaque(r, raw.headTop) : false,
    () => alphaHeadTop(r),
  );
  const handL = pick(raw?.handL, raw ? nearOpaque(r, raw.handL) : false, () => alphaHandFallback(r, 'L'));
  const handR = pick(raw?.handR, raw ? nearOpaque(r, raw.handR) : false, () => alphaHandFallback(r, 'R'));
  return { headTop, handL, handR, source: allNative ? 'vision' : 'fallback' };
}

/**
 * 编排入口：立绘（最终入库形态）→ 锚点。图片解码失败返回 null（appearance 不写 anchors，
 * 客户端按缺省兜底）；vision 失败/校验不过走像素兜底，正常返回。
 */
export async function detectCharacterAnchors(
  adapter: AnchorAdapter,
  image: ImageBlob,
): Promise<CharacterAnchors | null> {
  let raster: Raster;
  try {
    raster = decode(image.bytes);
  } catch (err) {
    console.warn(`锚点检测：立绘解码失败，跳过（${err instanceof Error ? err.message : err}）`);
    return null;
  }
  const raw = await adapter.detectAnchors(image);
  return validateAnchors(raster, raw);
}
