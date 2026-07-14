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
];

const BLUEPRINT_BY_ID = new Map(BUILD_BLUEPRINTS.map((b) => [b.id, b]));

/** 按 id 查蓝图（未知 undefined）。 */
export function findBlueprint(id: string): WholeBlueprint | undefined {
  return BLUEPRINT_BY_ID.get(id);
}

/** 一副蓝图的必填槽（全满才可落成）。 */
export function requiredSlots(bp: WholeBlueprint): BlueprintSlot[] {
  return bp.slots.filter((s) => s.required);
}

/** 所有蓝图槽里出现过的 accept 类别（蓝图端视角）。用于与零件端做双向自洽校验。 */
export function blueprintAcceptCategories(): Set<string> {
  const s = new Set<string>();
  for (const bp of BUILD_BLUEPRINTS) for (const sl of bp.slots) s.add(sl.accept);
  return s;
}
