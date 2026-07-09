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
 * 动森纸片画风+绿幕背景并抠图，所以这里只描述「画什么主体」。抽象类别(颜色/大小/特点/性格)
 * 映射成一个具体可画的东西:颜色→彩色气球、大小→不同大小的生物、特点→象征物、性格→表情脸。
 */
export const ICON_PROMPTS: Record<string, string> = {
  // kind
  cat: 'a cute kitten', dog: 'a cute puppy', rabbit: 'a cute bunny rabbit',
  dragon: 'a cute friendly baby dragon', bird: 'a cute little bird', fish: 'a cute goldfish',
  bear: 'a cute teddy bear', person: 'a cute cartoon child kid', sprite: 'a cute magical fairy sprite',
  // color → 彩色气球（颜色一眼可辨，抠图后仍是纯色主体）
  red: 'a bright red balloon', orange: 'a bright orange balloon', yellow: 'a bright yellow balloon',
  green: 'a bright green balloon', blue: 'a bright blue balloon', purple: 'a bright purple balloon',
  pink: 'a bright pink balloon', white: 'a white balloon', black: 'a black balloon',
  // size → 不同大小的生物（抠图归一后靠体型/比例暗示，不完美但可辨）
  small: 'a tiny baby chick', medium: 'a medium-sized puppy', big: 'a giant elephant',
  // trait → 象征物
  fly: 'a pair of white feathery angel wings', swim: 'a cute fish with water splash',
  fluffy: 'a fluffy ball of soft fur', glow: 'a glowing shiny yellow star',
  horn: 'a single magical unicorn horn', wings: 'a pair of colorful butterfly wings',
  // personality → 表情脸
  lively: 'a happy laughing cartoon face', gentle: 'a gentle warm smiling face',
  brave: 'a brave confident face with a superhero cape', shy: 'a shy blushing cartoon face',
  smiley: 'a big cheerful smiley face',
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
