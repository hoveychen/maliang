import type { AnchorAdapter, ImageBlob, RawAnchorPoints } from './types.ts';
import type { OpenRouterClient } from './openrouter_client.ts';

/**
 * 立绘锚点指点检测（OpenRouter vision 看图返回归一化点位）。
 * Prompt 为 2026-07-12 PoC 原文微调（12/12 实证，含四足/鸟/龙非人形）：
 * - head_top 按「帽子该戴的头顶正位」问——长耳角色答两耳之间，优于 alpha 最高点（耳尖）；
 * - 左右手按画面方位（viewer's left/right）问，与存储坐标系一致，无需翻转换算；
 * - 无四肢的兜底语义（中腰身体边缘）也交给模型，服务端另有像素级合法性校验（anchors.ts）。
 * 任何网络/解析失败一律回 null——保险丝坏了不能拦住主管线（与朝向检测同哲学）。
 */
const PROMPT =
  'This is a full-body character illustration (transparent background, kids game). ' +
  'The character may be humanoid, an animal, or a fantasy creature. ' +
  'Point to these anchor locations on the image:\n' +
  '1. "head_top": the very top-center of the head (where a hat would sit).\n'
  + '2. "left_hand": the character\'s hand/paw/wing-tip on the LEFT SIDE OF THE IMAGE '
  + '(viewer\'s left) - where it could hold an object. If no limbs, the left edge of the body at mid-height.\n'
  + '3. "right_hand": same but on the right side of the image.\n'
  + 'Answer with ONLY a JSON array, each element {"label": string, "x": int, "y": int} '
  + 'where x and y are normalized to 0-1000 relative to image width and height.';

export class OpenRouterAnchorAdapter implements AnchorAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;

  constructor(client: OpenRouterClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async detectAnchors(image: ImageBlob): Promise<RawAnchorPoints | null> {
    try {
      const answer = await this.#client.chatVision(this.#model, PROMPT, image);
      return parseAnchorAnswer(answer);
    } catch (err) {
      console.warn(`锚点检测失败（走兜底）: ${err instanceof Error ? err.message : err}`);
      return null;
    }
  }
}

/** 从模型回答里解析三点（0-1000 → 0-1）。缺任一点/坐标非数值/越界 → null（整体走兜底）。 */
export function parseAnchorAnswer(answer: string): RawAnchorPoints | null {
  const m = /\[[\s\S]*\]/.exec(answer);
  if (!m) return null;
  let arr: unknown;
  try {
    arr = JSON.parse(m[0]);
  } catch {
    return null;
  }
  if (!Array.isArray(arr)) return null;
  const byLabel = new Map<string, { x: number; y: number }>();
  for (const it of arr) {
    const o = it as { label?: unknown; x?: unknown; y?: unknown };
    if (typeof o?.label !== 'string' || typeof o.x !== 'number' || typeof o.y !== 'number') continue;
    if (o.x < 0 || o.x > 1000 || o.y < 0 || o.y > 1000) continue;
    byLabel.set(o.label, { x: o.x / 1000, y: o.y / 1000 });
  }
  const headTop = byLabel.get('head_top');
  const handL = byLabel.get('left_hand');
  const handR = byLabel.get('right_hand');
  if (!headTop || !handL || !handR) return null;
  return { headTop, handL, handR };
}
