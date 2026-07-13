/**
 * 立绘统一画风（温馨玩具感村庄 chibi 底子 + 模切贴纸感：粗黑描边 + 白色贴纸裁切边 + 扁平上色）。
 * 统一 3/4 侧身朝右——客户端水平翻转即得朝左，避免正面立绘左右移动的「螃蟹步」。
 * 风格/构图/绿幕约束在服务端拼接，不依赖 LLM 在 visualDescription 里自觉带上——
 * LLM 只负责描述角色主体（种类/配色/服饰/表情）。
 *
 * 措辞里不写任何 IP 名（曾写过 "Animal Crossing style" / "like Paper Mario"）：
 * 那两个词会让 FLUX 全系与微软 MAI 直接以 Protected Content 为由拒绝整条请求，
 * 把我们锁死在 Google 一家。实测换成纯描述性措辞后画风不掉（评测见 wiki maliang/image-model-eval）。
 */
export const SPRITE_STYLE_SUFFIX =
  'cute chibi cartoon character in a cozy toy-like village game art style, big head, small round body, ' +
  'die-cut paper sticker style: strong clean silhouette with a bold black outline ' +
  'around the character and a thick white sticker border outside the outline, ' +
  'flat cel shading, bright pastel colors, toy-like, ' +
  'full body, centered, three-quarter side view with the whole body and face facing right, ' +
  'on a pure solid chroma-green #00FF00 background, ' +
  'no shadows, no text, no watermark';

export function buildSpritePrompt(visualDescription: string): string {
  const subject = visualDescription.trim().replace(/[.。，,]+$/, '');
  return `${subject}. ${SPRITE_STYLE_SUFFIX}`;
}

/**
 * 图标画风（引导式造角色的选项卡，见 docs/guided-creation-design.md §4）：
 * 保留纸片马里奥贴纸感（扁平上色 + 粗黑描边），但**不套角色框**——不要 chibi 大头小身、
 * 不要脸/手脚、不要全身朝右。只画「一个居中的简单符号/物体」，抽象概念别拟人化。
 * 白色 die-cut 贴纸边不靠模型画（模型不稳），交给 addStickerBorder 程序后期描。
 */
export const ICON_STYLE_SUFFIX =
  'flat 2D sticker icon, a single centered simple subject, bold clean black outline, ' +
  'flat cel shading with bright solid colors, minimal and iconic, thick and chunky shapes, ' +
  'NOT a character illustration, do NOT add a face, eyes, arms or legs unless the subject itself is a face or creature, ' +
  'no full-body pose, no 3/4 view, front-facing flat, ' +
  'on a pure solid chroma-green #00FF00 background, no shadow, no ground, no text, no watermark';

export function buildIconPrompt(visualDescription: string): string {
  const subject = visualDescription.trim().replace(/[.。，,]+$/, '');
  return `${subject}. ${ICON_STYLE_SUFFIX}`;
}

/**
 * 点点（引导精灵）的形象主体：娜薇式发光小仙子——迷你仙子女孩 + 青蓝光晕 +
 * 透明虫翅 + 星尘，游戏内按头部大小悬浮渲染。统一画风后缀仍由 buildSpritePrompt 拼接。
 */
export const FAIRY_VISUAL_DESC =
  '一个发光的迷你小仙子女孩，全身包裹着柔和的青蓝色光球光晕，四片透明闪亮的蜻蜓翅膀，' +
  '圆脸大眼睛温柔微笑，短短的淡蓝色头发，小小的白裙子，身后拖着闪烁的星星光尘';
