import type { CreationCategory, CreationOption, CreationAttrs } from './types.ts';
import { CREATION_OPTIONS } from './creation_options.ts';

/**
 * 引导式造物品的图标库（与造角色 creation_options.ts 平行）。
 * 造物问四类：kind(什么东西) / color(颜色) / size(大小) / motion(会不会动)。
 *
 * color 与 size 直接复用造角色图标库的同 id 选项——一滴颜料、体型剪影对物品同样成立，
 * 图标资产（store.getCreationIcon(id)）也共享同一份，省一半生成成本。
 * 只有 kind(物品种类) 与 motion(会不会动) 是造物专属、需新生成的图标。
 */

/** 造物可问的类别。 */
export const PROP_CREATION_CATEGORIES: readonly CreationCategory[] = ['kind', 'color', 'size', 'motion'];

function opt(id: string, category: CreationCategory, label: string): CreationOption {
  return { id, category, label, iconAsset: '' };
}

// 从造角色库借来的 color/size 选项（同 id、同 label、共享图标资产）。
const SHARED_COLOR_SIZE: readonly CreationOption[] = CREATION_OPTIONS.filter(
  (o) => o.category === 'color' || o.category === 'size',
);

/** 造物专属的新图标（kind 物品种类 + motion 会不会动）。id 加 prop_ 前缀，不与造角色 kind 撞。 */
const PROP_OWN_OPTIONS: readonly CreationOption[] = [
  // kind 物品种类
  opt('prop_flower', 'kind', '小花'), opt('prop_pinwheel', 'kind', '风车'),
  opt('prop_house', 'kind', '小房子'), opt('prop_sign', 'kind', '路牌'),
  opt('prop_ball', 'kind', '球'), opt('prop_star', 'kind', '星星'),
  opt('prop_mushroom', 'kind', '蘑菇'), opt('prop_lantern', 'kind', '灯笼'),
  opt('prop_drum', 'kind', '小鼓'),
  // motion 会不会动
  opt('prop_still', 'motion', '安安静静'), opt('prop_spin', 'motion', '会转圈'),
  opt('prop_float', 'motion', '会飘'), opt('prop_hop', 'motion', '会跳'),
];

/** 造物图标库全表：造物专属（kind+motion）+ 复用造角色的 color/size。 */
export const PROP_CREATION_OPTIONS: readonly CreationOption[] = [...PROP_OWN_OPTIONS, ...SHARED_COLOR_SIZE];

/**
 * 造物专属图标的生图主体描述（英文；图标生成管线用；走 buildIconPrompt 统一贴纸画风）。
 * kind 是实物（小花/风车…）；motion 是抽象概念，用象征记号表达，绝不加脸/手脚。
 * color/size 不在此表——它们复用造角色 ICON_PROMPTS 里的同 id。
 */
export const PROP_ICON_PROMPTS: Record<string, string> = {
  // kind → 物品贴纸（实物，无脸）
  prop_flower: 'a cute simple daisy flower with a round center, no face',
  prop_pinwheel: 'a cute colorful paper pinwheel on a stick',
  prop_house: 'a cute tiny cartoon cottage house with a triangle roof, no face',
  prop_sign: 'a cute wooden signpost with a blank arrow board',
  prop_ball: 'a cute glossy striped play ball',
  prop_star: 'a cute plump five-point star, no face',
  prop_mushroom: 'a cute round-cap toadstool mushroom, no face',
  prop_lantern: 'a cute round paper lantern glowing warmly',
  prop_drum: 'a cute little toy drum with two drumsticks',
  // motion → 抽象记号（绝不加脸/手脚）
  prop_still: 'a minimal icon of three small "Zzz" sleep marks, calm and quiet, clean thin line style',
  prop_spin: 'a minimal icon of two curved circular rotation arrows forming a ring, clean thin line style',
  prop_float: 'a minimal icon of an upward floating balloon with a small cloud, clean thin line style',
  prop_hop: 'a minimal icon of a bouncing dashed arc trajectory with an up arrow, clean thin line style',
};

const BY_ID = new Map(PROP_CREATION_OPTIONS.map((o) => [o.id, o]));
const BY_LABEL = new Map(PROP_CREATION_OPTIONS.map((o) => [o.label, o]));

/** 按类别取造物选项。 */
export function propOptionsByCategory(category: CreationCategory): CreationOption[] {
  return PROP_CREATION_OPTIONS.filter((o) => o.category === category);
}

/** 按 id 查造物选项（未知 undefined）。 */
export function findPropOption(id: string): CreationOption | undefined {
  return BY_ID.get(id);
}

/** 按中文 label 查造物选项。 */
export function findPropOptionByLabel(label: string): CreationOption | undefined {
  return BY_LABEL.get(label.trim());
}

/** 造物专属图标的生图 prompt；color/size 复用造角色的（调用方对这些 id 走 iconPrompt）。 */
export function propIconPrompt(id: string): string {
  return PROP_ICON_PROMPTS[id] ?? `a cute ${id}`;
}

/** 追问每个类别的问法（mock 固定文案；真实由 LLM 按仙子口吻生成）。 */
export const PROP_CREATION_ASK: Record<CreationCategory, string> = {
  kind: '你想变出什么呀？',
  color: '它是什么颜色的呢？',
  size: '要大大的还是小小的？',
  motion: '它会动吗，还是安安静静的？',
  // 造物用不到，占位满足 Record 类型
  trait: '它有什么特别的地方吗？',
  personality: '（造物不问性格）',
  name: '（造物不起名）',
};

/** 把造物累积属性汇成给 designSdfProp 的中文描述。 */
export function composePropDesc(a: CreationAttrs): string {
  const head = `一个${a.color ?? ''}${a.size ?? ''}的${a.kind ?? '小物件'}`;
  const parts = [head];
  if (a.motion && a.motion !== '安安静静') parts.push(a.motion);
  return parts.join('，');
}
