// 积木式造物（B1，docs/kids-thinking-build-from-parts.md）预置零件库。
// 与 creation_options.ts / prop_creation_options.ts 平行：代码常量、可单测、零迁移。
//
// 一个「零件」PartDef 是能填进整体蓝图某个槽的一块小图。教育核心（分解+组合）用有界词表
// 跑得最好——孩子说出「轮子」、从几个预置轮子里挑一个，就是分解+组合的全部。LLM 现造零件
// （renderRef 'part:@<hash>'，照 sticker:@<hash> 约定）是独立后续 PRD，此处只占语法、不实现。
//
// renderRef 现为占位 'part:<id>'（客户端打包资源）；真图由 P3 批量生成管线填入。

export interface PartDef {
  /** 全局唯一 id，如 'wheel_round'。 */
  id: string;
  /** 语义类（点点问功能后归类到这里），如 '轮子' / '车厢' / '屋顶'。孩子听到/看到的中文归类。 */
  category: string;
  /** 中文名（孩子听到/看到），如 '圆轮子'。 */
  name: string;
  /** 渲染引用。预置：'part:<id>'（客户端打包）；预留 'part:@<hash>'（未来 LLM 现造）。 */
  renderRef: string;
  /** 可挂到哪种整体的哪类槽（与 WholeBlueprint.slots[].accept 对齐）。一个零件可通用于多种整体。 */
  fitSlots: readonly string[];
}

function part(id: string, category: string, name: string, fitSlots: readonly string[]): PartDef {
  return { id, category, name, renderRef: `part:${id}`, fitSlots };
}

/**
 * 预置零件库全表。
 * 注意几处刻意的「一件多用」——同一个轮子既能装小车也能装小火车、同一根烟囱既上房子也上火车头。
 * 这不是偷懒：它正是 B3（复用/起名）要教的「同一块积木用在很多地方」，在库里就先立起来。
 */
export const PART_LIBRARY: readonly PartDef[] = [
  // 轮子（小车 + 小火车共用）
  part('wheel_round', '轮子', '圆轮子', ['car.wheel', 'train.wheel']),
  part('wheel_star', '轮子', '星星轮子', ['car.wheel', 'train.wheel']),
  part('wheel_flower', '轮子', '小花轮子', ['car.wheel', 'train.wheel']),
  // 车身
  part('body_box', '车身', '方箱车身', ['car.body']),
  part('body_round', '车身', '圆滚车身', ['car.body']),
  part('body_truck', '车身', '卡车车身', ['car.body']),
  // 把手
  part('handle_curve', '把手', '弯把手', ['car.handle']),
  part('handle_straight', '把手', '直把手', ['car.handle']),
  // 墙
  part('wall_brick', '墙', '砖头墙', ['house.wall']),
  part('wall_wood', '墙', '木头墙', ['house.wall']),
  part('wall_stone', '墙', '石头墙', ['house.wall']),
  // 屋顶
  part('roof_tri', '屋顶', '三角屋顶', ['house.roof']),
  part('roof_flat', '屋顶', '平平屋顶', ['house.roof']),
  part('roof_dome', '屋顶', '圆圆屋顶', ['house.roof']),
  // 门
  part('door_arch', '门', '拱门', ['house.door']),
  part('door_square', '门', '方门', ['house.door']),
  // 窗
  part('window_round', '窗', '圆窗', ['house.window']),
  part('window_square', '窗', '方窗', ['house.window']),
  // 烟囱（房子 + 火车头共用）
  part('chimney_brick', '烟囱', '砖烟囱', ['house.chimney', 'train.chimney']),
  part('chimney_pipe', '烟囱', '铁皮烟囱', ['house.chimney', 'train.chimney']),
  // 火车头
  part('engine_classic', '火车头', '老式火车头', ['train.engine']),
  part('engine_bullet', '火车头', '子弹火车头', ['train.engine']),
  // 车厢
  part('car_open', '车厢', '敞篷车厢', ['train.car']),
  part('car_closed', '车厢', '带顶车厢', ['train.car']),
  // 雪人：大/小雪球
  part('snowball_big', '大雪球', '大雪球', ['snow.big']),
  part('snowball_big_sparkle', '大雪球', '亮晶晶大雪球', ['snow.big']),
  part('snowball_small', '小雪球', '小雪球', ['snow.small']),
  part('snowball_small_sparkle', '小雪球', '亮晶晶小雪球', ['snow.small']),
  // 雪人：帽子/鼻子
  part('hat_top', '帽子', '高礼帽', ['snow.hat']),
  part('hat_bucket', '帽子', '小水桶帽', ['snow.hat']),
  part('nose_carrot', '鼻子', '胡萝卜鼻子', ['snow.nose']),
  part('nose_button', '鼻子', '纽扣鼻子', ['snow.nose']),
];

const PART_BY_ID = new Map(PART_LIBRARY.map((p) => [p.id, p]));

/** 按 id 查零件（未知 undefined）。 */
export function findPart(id: string): PartDef | undefined {
  return PART_BY_ID.get(id);
}

/** 取所有能填进某类槽（accept）的零件——拼装台点亮某槽时，零件盘就列这些。 */
export function partsForSlot(accept: string): PartDef[] {
  return PART_LIBRARY.filter((p) => p.fitSlots.includes(accept));
}

/** 库里出现过的所有 accept 类别（零件端视角）。用于与蓝图端做双向自洽校验。 */
export function partAcceptCategories(): Set<string> {
  const s = new Set<string>();
  for (const p of PART_LIBRARY) for (const a of p.fitSlots) s.add(a);
  return s;
}
