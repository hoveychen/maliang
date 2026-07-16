// 积木式造物（B1，docs/kids-thinking-build-from-parts.md）整体蓝图库。
// 一副蓝图 = 一个整体（小车/房子…）声明它由哪些「带名字的槽」组成。孩子把零件（part_library.ts）
// 逐槽填入，必填槽全满 → 落成。槽本身就是脚手架：空槽发光、一个一个亮，就是「这个整体缺哪几块」
// 的可视清单，孩子不必记住小车有几个部件，骨架替他记着。
//
// slot.accept 与 PartDef.fitSlots 必须双向自洽（build_library.test.ts 守）：
//   - 每个槽的 accept 至少有 2 个零件能填（孩子要有得挑）；
//   - 每个零件的 fitSlots 都指向某个真实存在的槽 accept（无孤儿零件）。
//
// baseRef/零件 renderRef 现为占位；骨架底板图与零件图由 P3 批量生成管线填入。

/** 归一化相对位姿（相对骨架底板，同角色锚点的归一化约定）：x/y ∈ [0,1]，scale > 0，rot 弧度。 */
export interface SlotPose {
  x: number;
  y: number;
  scale: number;
  rot: number;
}

export interface BlueprintSlot {
  /** 槽 id，蓝图内唯一，如 'wheel_front'。 */
  slotId: string;
  /** 收哪类零件（与 PartDef.fitSlots 对齐），如 'car.wheel'。 */
  accept: string;
  /** 槽在骨架上的相对位姿。 */
  pose: SlotPose;
  /** 点点提问的功能线索（'能滚起来'）——驱动分解，绝不是给答案（不出现零件名）。 */
  functionHint: string;
  /** 必填槽全满才可落成；选填槽可留空。 */
  required: boolean;
}

export interface WholeBlueprint {
  /** 蓝图 id，如 'car'。 */
  id: string;
  /** 中文名（孩子听到/看到），如 '小车'。 */
  name: string;
  /** 骨架底板图（拼装时半透明显示，空槽在它上面发光）。占位 'blueprint:<id>'，P3 填真图。 */
  baseRef: string;
  slots: readonly BlueprintSlot[];
}

function slot(
  slotId: string,
  accept: string,
  functionHint: string,
  required: boolean,
  pose: SlotPose,
): BlueprintSlot {
  return { slotId, accept, functionHint, required, pose };
}

/** 首批蓝图：小车 / 小房子 / 小火车 / 雪人。都是幼儿园一眼认得、明显「由零件拼成」的东西。 */
export const BUILD_BLUEPRINTS: readonly WholeBlueprint[] = [
  {
    id: 'car',
    name: '小车',
    baseRef: 'blueprint:car',
    slots: [
      slot('body', 'car.body', '东西要放上去，坐在哪儿呢', true, { x: 0.5, y: 0.45, scale: 1.0, rot: 0 }),
      slot('wheel_back', 'car.wheel', '它要能滚起来，得有什么圆圆的', true, { x: 0.32, y: 0.78, scale: 0.5, rot: 0 }),
      slot('wheel_front', 'car.wheel', '另一边也要能滚', true, { x: 0.68, y: 0.78, scale: 0.5, rot: 0 }),
      slot('handle', 'car.handle', '你想拉着它到处跑，手抓哪儿呀', true, { x: 0.85, y: 0.32, scale: 0.6, rot: 0 }),
    ],
  },
  {
    id: 'house',
    name: '小房子',
    baseRef: 'blueprint:house',
    slots: [
      slot('wall', 'house.wall', '要有个能挡风的身子，围起来的是什么', true, { x: 0.5, y: 0.62, scale: 1.0, rot: 0 }),
      slot('roof', 'house.roof', '下雨了，头顶要盖什么', true, { x: 0.5, y: 0.28, scale: 1.0, rot: 0 }),
      slot('door', 'house.door', '人要进进出出，得开个什么', true, { x: 0.5, y: 0.72, scale: 0.5, rot: 0 }),
      slot('window', 'house.window', '想看外面的太阳，得留个什么', false, { x: 0.72, y: 0.55, scale: 0.35, rot: 0 }),
      slot('chimney', 'house.chimney', '烧火的烟要往哪儿冒', false, { x: 0.7, y: 0.18, scale: 0.4, rot: 0 }),
    ],
  },
  {
    id: 'train',
    name: '小火车',
    baseRef: 'blueprint:train',
    slots: [
      slot('engine', 'train.engine', '火车最前面拉着大家跑的是什么', true, { x: 0.24, y: 0.45, scale: 1.0, rot: 0 }),
      slot('carriage', 'train.car', '后面装人装货的一节叫什么', true, { x: 0.66, y: 0.48, scale: 1.0, rot: 0 }),
      slot('wheel_a', 'train.wheel', '它要在铁轨上滚，得有什么', true, { x: 0.24, y: 0.82, scale: 0.4, rot: 0 }),
      slot('wheel_b', 'train.wheel', '另一节也要能滚', true, { x: 0.66, y: 0.82, scale: 0.4, rot: 0 }),
      slot('funnel', 'train.chimney', '老火车头会噗噗冒烟，冒烟的是什么', false, { x: 0.24, y: 0.18, scale: 0.4, rot: 0 }),
    ],
  },
  {
    id: 'snowman',
    name: '雪人',
    baseRef: 'blueprint:snowman',
    slots: [
      slot('base', 'snow.big', '雪人站得稳，最下面要滚个什么大的', true, { x: 0.5, y: 0.72, scale: 1.0, rot: 0 }),
      slot('torso', 'snow.small', '上面再叠一个什么小一点的', true, { x: 0.5, y: 0.4, scale: 0.7, rot: 0 }),
      slot('hat', 'snow.hat', '天冷了，头上戴个什么', false, { x: 0.5, y: 0.16, scale: 0.6, rot: 0 }),
      slot('nose', 'snow.nose', '脸中间尖尖的、能闻味道的是什么', false, { x: 0.5, y: 0.4, scale: 0.25, rot: 0 }),
    ],
  },
  // 蛋糕：教「叠层」——胚→奶油→顶料一层层往上叠（分解=一层是一件事）。女生向找平的第一副。
  {
    id: 'cake',
    name: '蛋糕',
    baseRef: 'blueprint:cake',
    slots: [
      slot('base', 'cake.base', '最下面厚厚的一大块，是什么呀', true, { x: 0.5, y: 0.7, scale: 1.0, rot: 0 }),
      slot('cream', 'cake.cream', '抹在外面白白的、甜甜的是什么', true, { x: 0.5, y: 0.52, scale: 0.95, rot: 0 }),
      slot('topping', 'cake.topping', '上面点缀的、一颗一颗红红的是什么', true, { x: 0.5, y: 0.34, scale: 0.5, rot: 0 }),
      slot('candle', 'cake.candle', '过生日要吹的、亮亮的是什么', false, { x: 0.5, y: 0.18, scale: 0.4, rot: 0 }),
    ],
  },
  // 花：教「功能分解」——要能站起来=茎、围一圈张开=花瓣、中间装花粉=花心（问功能不给答案的最佳载体）。
  {
    id: 'flower',
    name: '小花',
    baseRef: 'blueprint:flower',
    slots: [
      slot('petals', 'flower.petals', '围着中间一圈一圈张开的、五颜六色的是什么', true, { x: 0.5, y: 0.4, scale: 1.0, rot: 0 }),
      slot('center', 'flower.center', '花正中间圆圆的、装花粉的是什么', true, { x: 0.5, y: 0.4, scale: 0.4, rot: 0 }),
      slot('stem', 'flower.stem', '要能站起来，得有根绿绿的什么撑着', true, { x: 0.5, y: 0.74, scale: 0.9, rot: 0 }),
      slot('leaf', 'flower.leaf', '两边张开、能晒到太阳的是什么', false, { x: 0.64, y: 0.64, scale: 0.5, rot: 0 }),
    ],
  },
  // 冰淇淋：同蛋糕一路教「叠层」——甜筒托着球、球上再淋顶料（雪糕别名亦命中）。
  {
    id: 'icecream',
    name: '冰淇淋',
    baseRef: 'blueprint:icecream',
    slots: [
      slot('cone', 'ice.cone', '拿在手里、尖尖的能装东西的是什么', true, { x: 0.5, y: 0.74, scale: 0.8, rot: 0 }),
      slot('scoop', 'ice.scoop', '圆圆的、凉凉的一大坨是什么', true, { x: 0.5, y: 0.42, scale: 0.9, rot: 0 }),
      slot('topping', 'ice.topping', '淋在最上面、甜甜的是什么', false, { x: 0.5, y: 0.24, scale: 0.4, rot: 0 }),
    ],
  },
];

/** 组合物里的一个零件坐位：某个槽填了哪个零件（partRenderRef 冗余进来供客户端直接画子 quad，免二次查库）。 */
export interface ComposedPart {
  slotId: string;
  partId: string;
  partRenderRef: string;
}

/**
 * 组合物的持久化形状——`ItemDef.spec` 在 `renderRef='composed:'` 时取此形（docs/kids-thinking-build-from-parts.md §3.1）。
 * 成品永久存成「骨架 + 一棵零件树」而非拍平成一张图：轮子事后还能换、车厢还能挪去拼别的，
 * 架构思维的「可拆可复用」才落地（B3 的复用/改装直接编辑本 spec 生成新 ItemDef，无需新机制）。
 */
export interface ComposedSpec {
  blueprintId: string;
  parts: ComposedPart[];
}

const BLUEPRINT_BY_ID = new Map(BUILD_BLUEPRINTS.map((b) => [b.id, b]));

/** 按 id 查蓝图（未知 undefined）。 */
export function findBlueprint(id: string): WholeBlueprint | undefined {
  return BLUEPRINT_BY_ID.get(id);
}

/**
 * 蓝图别名词——`create_prop` 入口据此判断孩子想造的东西是否「有蓝图可拼」（有则把造物升级成积木拼装）。
 * name 本身（'小车'/'小房子'…）已在 matchBlueprint 里先查；这里只补 name 之外的常见叫法。
 * 刻意不收单字（「车」「房」）：太容易误命中，只在孩子明确说出整词时才升级到拼装。
 */
const BLUEPRINT_KEYWORDS: Record<string, readonly string[]> = {
  car: ['汽车', '小汽车', '车子'],
  house: ['房子', '屋子', '小屋'],
  train: ['火车'],
  snowman: ['雪人'],
  // 蛋糕 name='蛋糕' 已够特异（不像「车」会误伤），别名只补生日/奶油款。
  cake: ['生日蛋糕', '奶油蛋糕'],
  // 花 name 刻意取 '小花'（2 字）而非单字 '花'——否则 '烟花'/'棉花糖'/'花生' 全会误命中升级成拼花。
  // 别名同样都是含 '花' 的整词，仍不收单字。
  flower: ['花朵', '花儿', '鲜花'],
  // 冰淇淋别名收两种常见写法/叫法（冰激凌/雪糕）。
  icecream: ['冰激凌', '雪糕'],
};

/**
 * 把 create_prop 的口语描述匹配到一副蓝图（无匹配 undefined → 回落现有整体造物，优雅降级）。
 * 先查蓝图中文名整词命中，再查别名词；命中即把「许愿造一个东西」升级成「亲手拼一个东西」。
 */
export function matchBlueprint(request: string): WholeBlueprint | undefined {
  const text = request ?? '';
  if (!text) return undefined;
  for (const bp of BUILD_BLUEPRINTS) {
    if (text.includes(bp.name)) return bp;
    const kws = BLUEPRINT_KEYWORDS[bp.id] ?? [];
    if (kws.some((k) => text.includes(k))) return bp;
  }
  return undefined;
}

/** 一副蓝图的必填槽（全满才可落成）。 */
export function requiredSlots(bp: WholeBlueprint): BlueprintSlot[] {
  return bp.slots.filter((s) => s.required);
}

/**
 * 骨架底板图的统一画风——拼装时半透明浮在点点身旁，空槽在它上面发光（§3.4 隐形脚手架）。
 * 关键：底板是**淡的、虚的、没填零件的整体轮廓**，只让孩子看清「要拼的是个什么形状」，
 * 绝不能画成成品（画成成品孩子就没得拼了）。与零件图同一套童书简笔画风，好让填进去不违和。
 */
const BLUEPRINT_STYLE =
  'a faint pale grey dashed-outline blueprint sketch of the whole shape, very light and translucent, ' +
  'childlike storybook line style, empty with no parts filled in, front view, centered, ' +
  'fully transparent background, no scene, no ground, no color fill, no text';

/** 每副蓝图骨架底板的专属轮廓（虚线整体形，不含任何零件）。 */
const BLUEPRINT_SHAPE: Record<string, string> = {
  car: 'the empty outline of a simple side-view toy car (body area plus two round wheel spots and a pull-handle spot)',
  house: 'the empty outline of a simple front-view little house (a wall box plus a triangular roof spot)',
  train: 'the empty outline of a simple side-view little train (an engine spot plus one carriage spot on wheels)',
  snowman: 'the empty outline of a simple snowman (a big lower circle stacked with a smaller upper circle)',
  cake: 'the empty outline of a simple front-view layered birthday cake (a wide round base tier, a cream band above it, a small topping spot and a candle spot on top)',
  flower: 'the empty outline of a simple front-view flower (a round center spot ringed by petal spots, sitting on a straight stem with a side leaf spot)',
  icecream: 'the empty outline of a simple ice-cream cone (a pointed cone at the bottom holding a round scoop spot, with a small topping spot on top)',
};

/** 取某蓝图骨架底板的生图 prompt（统一画风前缀 + 专属轮廓；未知回退兜底）。P3 批量生成管线读它。 */
export function blueprintBasePrompt(id: string): string {
  const shape = BLUEPRINT_SHAPE[id];
  const bp = BLUEPRINT_BY_ID.get(id);
  if (!shape) return `${BLUEPRINT_STYLE}, the empty outline of a ${bp?.name ?? id}`;
  return `${BLUEPRINT_STYLE}, ${shape}`;
}

/** 所有蓝图槽里出现过的 accept 类别（蓝图端视角）。用于与零件端做双向自洽校验。 */
export function blueprintAcceptCategories(): Set<string> {
  const s = new Set<string>();
  for (const bp of BUILD_BLUEPRINTS) for (const sl of bp.slots) s.add(sl.accept);
  return s;
}
