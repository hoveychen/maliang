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

/**
 * 小神仙（引导精灵）的形象主体：娜薇式发光小仙子——迷你仙子女孩 + 青蓝光晕 +
 * 透明虫翅 + 星尘，游戏内按头部大小悬浮渲染。统一画风后缀仍由 buildSpritePrompt 拼接。
 */
export const FAIRY_VISUAL_DESC =
  '一个发光的迷你小仙子女孩，全身包裹着柔和的青蓝色光球光晕，四片透明闪亮的蜻蜓翅膀，' +
  '圆脸大眼睛温柔微笑，短短的淡蓝色头发，小小的白裙子，身后拖着闪烁的星星光尘';
