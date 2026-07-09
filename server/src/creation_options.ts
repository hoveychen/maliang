import type { CreationCategory, CreationOption } from './types.ts';

/**
 * 引导式造角色的预设图标库（见 docs/guided-creation-design.md §4）。
 * 每轮 guideCreation 从某一类别里挑 2–4 个 id 当选项，客户端渲染对应图标卡。
 * iconAsset 由 P3 图标生成管线填入（/assets/:hash）；本期先留空串（客户端可先用文字/占位）。
 * name 类别无图标（老板定：名字走语音），不进图标库。
 */

/** 造角色可问的类别，含 name（name 无图标，走语音）。 */
export const CREATION_CATEGORIES: readonly CreationCategory[] = [
  'kind', 'color', 'size', 'trait', 'personality', 'name',
];

/** 有图标的类别（name 除外）。 */
export const ICON_CATEGORIES: readonly CreationCategory[] = ['kind', 'color', 'size', 'trait', 'personality'];

function opt(id: string, category: CreationCategory, label: string): CreationOption {
  return { id, category, label, iconAsset: '' };
}

/** 图标库全表（老板定的 §4 默认清单为起点）。 */
export const CREATION_OPTIONS: readonly CreationOption[] = [
  // kind 类型
  opt('cat', 'kind', '猫'), opt('dog', 'kind', '狗'), opt('rabbit', 'kind', '兔'),
  opt('dragon', 'kind', '龙'), opt('bird', 'kind', '鸟'), opt('fish', 'kind', '鱼'),
  opt('bear', 'kind', '熊'), opt('person', 'kind', '小人'), opt('sprite', 'kind', '精灵'),
  // color 颜色
  opt('red', 'color', '红'), opt('orange', 'color', '橙'), opt('yellow', 'color', '黄'),
  opt('green', 'color', '绿'), opt('blue', 'color', '蓝'), opt('purple', 'color', '紫'),
  opt('pink', 'color', '粉'), opt('white', 'color', '白'), opt('black', 'color', '黑'),
  // size 大小
  opt('small', 'size', '小'), opt('medium', 'size', '中'), opt('big', 'size', '大'),
  // trait 特点
  opt('fly', 'trait', '会飞'), opt('swim', 'trait', '会游泳'), opt('fluffy', 'trait', '毛茸茸'),
  opt('glow', 'trait', '发光'), opt('horn', 'trait', '有角'), opt('wings', 'trait', '有翅膀'),
  // personality 性格
  opt('lively', 'personality', '活泼'), opt('gentle', 'personality', '温柔'),
  opt('brave', 'personality', '勇敢'), opt('shy', 'personality', '害羞'), opt('smiley', 'personality', '爱笑'),
];

/**
 * 每个选项的生图主体描述（英文；P3 图标生成用）。走 generateSprite 管线——它会统一追加
 * 画风走 buildIconPrompt(扁平贴纸图标,非角色框,不拟人化)。抽象类别用「合适符号」表达,
 * 绝不加脸/手脚:颜色→无脸颜料滴、大小→大小对比记号、特点→象征物、性格→表情丸脸(这类本就是脸)。
 */
export const ICON_PROMPTS: Record<string, string> = {
  // kind → 生物贴纸（本就是生物,可有脸）
  cat: 'a cute cat', dog: 'a cute puppy dog', rabbit: 'a cute bunny rabbit',
  dragon: 'a cute friendly baby dragon', bird: 'a cute little bird', fish: 'a cute goldfish',
  bear: 'a cute teddy bear', person: 'a cute cartoon kid', sprite: 'a cute magical fairy with wings',
  // color → 无脸的一滴颜料（纯色一眼可辨,绝不加脸/手脚）
  red: 'a single glossy droplet of bright red paint, no face', orange: 'a single glossy droplet of bright orange paint, no face',
  yellow: 'a single glossy droplet of bright yellow paint, no face', green: 'a single glossy droplet of bright green paint, no face',
  blue: 'a single glossy droplet of bright blue paint, no face', purple: 'a single glossy droplet of bright purple paint, no face',
  pink: 'a single glossy droplet of bright pink paint, no face', white: 'a single glossy droplet of white paint, no face',
  black: 'a single glossy droplet of black paint, no face',
  // size → 大小对比记号（一大一小圆,当前尺寸高亮上色,另一个灰色轮廓,无脸）
  small: 'a size comparison icon: a small bright orange circle next to a big gray outline circle, the small one highlighted, no face',
  medium: 'a size comparison icon: three circles in a row small medium large, only the middle medium circle is bright orange the others gray outline, no face',
  big: 'a size comparison icon: a big bright orange circle next to a small gray outline circle, the big one highlighted, no face',
  // trait → 象征物（clean symbol,无身体无脸）
  fly: 'a pair of white feathery angel wings, symbol only, no body no face',
  swim: 'a single blue water droplet with little wave ripples, symbol only, no face',
  fluffy: 'a soft fluffy white cloud of fur, symbol only, no face',
  glow: 'a bright glowing yellow star with sparkles, symbol only, no face',
  horn: 'a single spiral unicorn horn, symbol only, no body no face',
  wings: 'a pair of colorful butterfly wings, symbol only, no body no face',
  // personality → 表情丸脸（这类就是脸,合适）
  lively: 'a round face with a big open laughing smile and sparkly eyes',
  gentle: 'a round face with a soft gentle warm smile and calm eyes',
  brave: 'a round face with a determined confident brave expression',
  shy: 'a round blushing face with a shy little smile looking away',
  smiley: 'a round face with a simple big happy smile',
};

/** 取某选项的生图 prompt（未知回退到 label 兜底）。 */
export function iconPrompt(id: string): string {
  return ICON_PROMPTS[id] ?? `a cute ${id}`;
}

const BY_ID = new Map(CREATION_OPTIONS.map((o) => [o.id, o]));
const BY_LABEL = new Map(CREATION_OPTIONS.map((o) => [o.label, o]));

/** 按类别取该类的全部选项。 */
export function optionsByCategory(category: CreationCategory): CreationOption[] {
  return CREATION_OPTIONS.filter((o) => o.category === category);
}

/** 按 id 查选项（未知返回 undefined）。 */
export function findOption(id: string): CreationOption | undefined {
  return BY_ID.get(id);
}

/** 按中文 label 查选项（客户端/ASR 可能给 label 而非 id）。 */
export function findOptionByLabel(label: string): CreationOption | undefined {
  return BY_LABEL.get(label.trim());
}
