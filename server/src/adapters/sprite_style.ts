/**
 * 立绘统一画风（动森系 chibi，与 KayKit 场景资产同调）。
 * 风格/构图/绿幕约束在服务端拼接，不依赖 LLM 在 visualDescription 里自觉带上——
 * LLM 只负责描述角色主体（种类/配色/服饰/表情）。
 */
export const SPRITE_STYLE_SUFFIX =
  'cute chibi cartoon character in Animal Crossing style, big head, small round body, ' +
  'thick clean outlines, soft cel shading, bright pastel colors, toy-like, ' +
  'full body, centered, facing viewer, on a pure solid chroma-green #00FF00 background, ' +
  'no shadows, no text, no watermark';

export function buildSpritePrompt(visualDescription: string): string {
  const subject = visualDescription.trim().replace(/[.。，,]+$/, '');
  return `${subject}. ${SPRITE_STYLE_SUFFIX}`;
}
