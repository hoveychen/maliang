import type { ImageBlob, OrientationAdapter, SpriteFacing } from './types.ts';
import type { OpenRouterClient } from './openrouter_client.ts';

/**
 * 立绘朝向检测（OpenRouter vision 模型看图回答）。
 * 2026-07-08 用线上 8 张真图（含已知朝左/三视图/纯正面样本）实测定稿：
 * - 按「身体/脚的行走朝向」提问而非脸——「回头看」姿势按脸判会连贯地反
 *   （旧小狐身体朝左但脸转向右，按脸问 LEFT/RIGHT 两个模型都答 RIGHT，
 *   镜像自检也自洽地错，故弃镜像方案）；按身体问 8/8 符合预期。
 * - BAD 选项抓多角色三视图/裁切残图（gemini 偶发把 "full body, centered"
 *   画成三只并排的展示图，实测 BAD 能抓住）。
 * 任何网络/解析失败一律回 'unknown'——保险丝坏了不能拦住主管线。
 */
const PROMPT =
  'This is a cartoon character sprite for a side-scrolling game. ' +
  "Judge which horizontal direction the character's BODY is pointing (the direction it would walk), " +
  'based on the torso, legs and feet - ignore where the head or eyes are turned. ' +
  'Also check image quality. Answer with exactly one word:\n' +
  "RIGHT - body points to the viewer's right\n" +
  "LEFT - body points to the viewer's left\n" +
  'FRONT - body faces the viewer head-on, no clear left/right\n' +
  'BAD - the image shows multiple characters, or the character is cropped/cut off/incomplete';

export class OpenRouterOrientationAdapter implements OrientationAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;

  constructor(client: OpenRouterClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async detectFacing(image: ImageBlob): Promise<SpriteFacing> {
    try {
      const answer = await this.#client.chatVision(this.#model, PROMPT, image);
      return parseFacing(answer);
    } catch (err) {
      console.warn(`朝向检测失败（放行）: ${err instanceof Error ? err.message : err}`);
      return 'unknown';
    }
  }
}

/**
 * 从模型回答里解析朝向。边界用 [^a-z] 而非 \b：强制 reasoning 的模型会leak
 * 出 "RIGHT_of_thought" 这类粘连词（实测遇到），\b 会因下划线是 word char 而漏配；
 * 同时 "upright" 这种内嵌词仍不误配。
 */
export function parseFacing(answer: string): SpriteFacing {
  const m = /(?:^|[^a-z])(left|right|front|bad)(?:[^a-z]|$)/i.exec(answer);
  if (!m) return 'unknown';
  return m[1]!.toLowerCase() as SpriteFacing;
}
