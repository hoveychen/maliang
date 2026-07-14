import type { CreationCategory, CreationOption, CreationAttrs } from './types.ts';
import { CREATION_OPTIONS, recipientPhrase } from './creation_options.ts';

/**
 * 引导式造贴纸的图标库（与造角色 creation_options.ts / 造物 prop_creation_options.ts 平行）。
 * 造贴纸问两类：kind(什么图案) / color(颜色)。贴纸是扁平 die-cut 薄片，不问大小/会不会动/性格/名字。
 *
 * color 直接复用造角色图标库的同 id 选项——一滴颜料对贴纸同样成立，图标资产共享，省生成成本。
 * 只有 kind(图案) 是造贴纸专属、需新生成的图标，用 stk_ 前缀，不与造角色/造物 kind 撞。
 */

/** 造贴纸可问的类别。 */
export const STICKER_CREATION_CATEGORIES: readonly CreationCategory[] = ['kind', 'color'];

function opt(id: string, category: CreationCategory, label: string): CreationOption {
  return { id, category, label, iconAsset: '' };
}

// 从造角色库借来的 color 选项（同 id、同 label、共享图标资产）。
const SHARED_COLOR: readonly CreationOption[] = CREATION_OPTIONS.filter((o) => o.category === 'color');

/** 造贴纸专属的图案图标（kind）。id 加 stk_ 前缀，不与造角色/造物 kind 撞。 */
const STICKER_OWN_OPTIONS: readonly CreationOption[] = [
  opt('stk_sun', 'kind', '太阳'), opt('stk_flower', 'kind', '小花'),
  opt('stk_star', 'kind', '星星'), opt('stk_heart', 'kind', '爱心'),
  opt('stk_rainbow', 'kind', '彩虹'), opt('stk_butterfly', 'kind', '蝴蝶'),
  opt('stk_moon', 'kind', '月亮'), opt('stk_smile', 'kind', '笑脸'),
  opt('stk_cloud', 'kind', '云朵'), opt('stk_strawberry', 'kind', '草莓'),
];

/** 造贴纸图标库全表：造贴纸专属（kind 图案）+ 复用造角色的 color。 */
export const STICKER_CREATION_OPTIONS: readonly CreationOption[] = [...STICKER_OWN_OPTIONS, ...SHARED_COLOR];

/**
 * 造贴纸专属图案的生图主体描述（英文；图标生成管线用；走 buildIconPrompt 统一扁平贴纸画风）。
 * 全是扁平图案（实物/符号），绝不加脸/手脚（笑脸例外，它本就是脸）。
 * color 不在此表——它复用造角色 ICON_PROMPTS 里的同 id。
 */
export const STICKER_ICON_PROMPTS: Record<string, string> = {
  stk_sun: 'a cute simple flat cartoon sun with rounded rays',
  stk_flower: 'a cute simple flat daisy flower with rounded petals, no face',
  stk_star: 'a cute plump flat five-point star, no face',
  stk_heart: 'a cute glossy flat heart, no face',
  stk_rainbow: 'a cute flat rainbow arc with a small cloud at each end',
  stk_butterfly: 'a cute flat butterfly with symmetric patterned wings, top view, no face',
  stk_moon: 'a cute flat crescent moon, no face',
  stk_smile: 'a cute simple flat round smiley face, clean thin line style, two dot eyes and a curved smile',
  stk_cloud: 'a cute flat puffy cloud, no face',
  stk_strawberry: 'a cute flat strawberry with little seed dots and a green leaf top, no face',
};

/** 取造贴纸图案的生图 prompt（color 复用造角色的，故不在此表；未知回退到 label 兜底）。 */
export function stickerIconPrompt(id: string): string {
  return STICKER_ICON_PROMPTS[id] ?? `a cute flat sticker of ${id}`;
}

/** 追问每个类别的问法（mock 固定文案；真实由 LLM 按仙子口吻生成）。 */
export const STICKER_CREATION_ASK: Record<CreationCategory, string> = {
  kind: '你想做个什么图案的贴纸呀？',
  color: '要什么颜色的呢？',
  // 造贴纸用不到，占位满足 Record 类型
  size: '（贴纸不问大小）',
  motion: '（贴纸不问会不会动）',
  trait: '（贴纸不问特点）',
  personality: '（贴纸不问性格）',
  name: '（贴纸不起名）',
  recipient: '这个呀，是给谁做的呀？', // A2：recipient 就地组装，不经 guide；此处占位满足 Record 完整性
};

const BY_ID = new Map(STICKER_CREATION_OPTIONS.map((o) => [o.id, o]));
const BY_LABEL = new Map(STICKER_CREATION_OPTIONS.map((o) => [o.label, o]));

/** 按类别取造贴纸选项。 */
export function stickerOptionsByCategory(category: CreationCategory): CreationOption[] {
  return STICKER_CREATION_OPTIONS.filter((o) => o.category === category);
}

/** 按 id 查造贴纸选项（未知 undefined）。 */
export function findStickerOption(id: string): CreationOption | undefined {
  return BY_ID.get(id);
}

/** 按中文 label 查造贴纸选项（客户端/ASR 可能给 label 而非 id）。 */
export function findStickerOptionByLabel(label: string): CreationOption | undefined {
  return BY_LABEL.get(label.trim());
}

/** 把造贴纸累积属性汇成给 designSticker 的中文描述。 */
export function composeStickerDesc(a: CreationAttrs): string {
  const rp = recipientPhrase(a.recipient); // A2：「给X用的」进描述（贴纸尺寸固定，仅供语义/记忆）
  return `一个${a.color ?? ''}的${a.kind ?? '图案'}贴纸${rp ? `，${rp}` : ''}`;
}
