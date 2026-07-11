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
  // rabbit 要写清毛色与细节：只说 "a cute bunny rabbit" 时模型给了一块纯色剪影，
  // 既和同排有细节的猫狗不同调，又自带颜色会跟「颜色」那轮的选项打架。
  cat: 'a cute cat', dog: 'a cute puppy dog',
  rabbit: 'a cute fluffy white bunny rabbit with long ears and pink inner ears, sitting, front view, natural fur shading',
  dragon: 'a cute friendly baby dragon', bird: 'a cute little bird', fish: 'a cute goldfish',
  bear: 'a cute teddy bear', person: 'a cute cartoon kid', sprite: 'a cute magical fairy with wings',
  // color → 无脸的一滴颜料（纯色一眼可辨,绝不加脸/手脚）
  red: 'a single glossy droplet of bright red paint, no face', orange: 'a single glossy droplet of bright orange paint, no face',
  yellow: 'a single glossy droplet of bright yellow paint, no face', green: 'a single glossy droplet of bright green paint, no face',
  blue: 'a single glossy droplet of bright blue paint, no face', purple: 'a single glossy droplet of bright purple paint, no face',
  pink: 'a single glossy droplet of bright pink paint, no face', white: 'a single glossy droplet of white paint, no face',
  black: 'a single glossy droplet of black paint, no face',
  // size → 体型剪影（瘦/正常/胖）。三张要能横着比：**同一个灰色、同一个站姿、同样全身**，
  // 只有胖瘦不同。旧版没锁死这些，模型每张换一个颜色、中号还只画了半身，三张摆一起看不出大小。
  small: 'a minimal icon of one full-body standing figure silhouette from head to feet, filled solid medium grey, front view, arms down at the sides, very thin narrow skinny body, identical grey color and identical standing pose to the medium and big body icons, no face',
  medium: 'a minimal icon of one full-body standing figure silhouette from head to feet, filled solid medium grey, front view, arms down at the sides, normal average width body, identical grey color and identical standing pose to the small and big body icons, no face',
  big: 'a minimal icon of one full-body standing figure silhouette from head to feet, filled solid medium grey, front view, arms down at the sides, very wide fat round chubby body, identical grey color and identical standing pose to the small and medium body icons, no face',
  // trait → 象征物（clean symbol,无身体无脸;会飞/会游泳要动感）
  // fly 只留翅膀：旧版说 "a bird soaring" 时模型画出了长翅膀的鱼，和隔壁「会游泳」的鱼撕不开。
  fly: 'a dynamic action icon of a pair of feathered wings spread wide and flapping upward with curved speed motion lines, wings only, no bird, no animal body, no fish, symbol only, no face',
  swim: 'a dynamic action icon of a fish diving through curvy water waves with splash and motion lines showing swimming, symbol only, no face',
  fluffy: 'a round fuzzy furball completely covered in soft fur with many little fur tufts and spikes sticking out all around the edge, NOT a cloud, symbol only, no face',
  glow: 'a bright glowing yellow star with radiating sparkles, symbol only, no face',
  horn: 'a single spiral unicorn horn, symbol only, no body no face',
  wings: 'a pair of colorful butterfly wings, symbol only, no body no face',
  // personality → 极简统一的圆脸表情符号（同一套扁平线条脸,只表情不同）
  lively: 'a minimal flat simple round emoji face, clean thin line style, big open grin with sparkle eyes',
  gentle: 'a minimal flat simple round emoji face, clean thin line style, soft closed-eye gentle smile',
  brave: 'a minimal flat simple round emoji face, clean thin line style, determined straight eyebrows and confident smile',
  shy: 'a minimal flat simple round emoji face, clean thin line style, two round blush cheeks and a small wavy shy smile',
  smiley: 'a minimal flat simple round emoji face, clean thin line style, two dot eyes and a simple curved smile',
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
