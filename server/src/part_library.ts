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
  // ── 蛋糕（教叠层）──
  // 蛋糕胚
  part('base_round', '蛋糕胚', '圆胚', ['cake.base']),
  part('base_square', '蛋糕胚', '方胚', ['cake.base']),
  part('base_heart', '蛋糕胚', '爱心胚', ['cake.base']),
  // 奶油层
  part('cream_white', '奶油层', '白奶油', ['cake.cream']),
  part('cream_pink', '奶油层', '粉奶油', ['cake.cream']),
  part('cream_choco', '奶油层', '巧克力奶油', ['cake.cream']),
  // 顶料（樱桃/彩针与冰淇淋共用同类语义，但各有独立 id）
  part('top_strawberry', '顶料', '草莓', ['cake.topping']),
  part('top_cherry', '顶料', '樱桃', ['cake.topping']),
  part('top_star', '顶料', '小星星糖', ['cake.topping']),
  // 蜡烛
  part('candle_one', '蜡烛', '单蜡烛', ['cake.candle']),
  part('candle_number', '蜡烛', '数字蜡烛', ['cake.candle']),
  // ── 花（教功能分解）──
  // 花心
  part('center_yellow', '花心', '黄花心', ['flower.center']),
  part('center_orange', '花心', '橙花心', ['flower.center']),
  part('center_dot', '花心', '圆点花心', ['flower.center']),
  // 花瓣
  part('petals_round', '花瓣', '圆花瓣', ['flower.petals']),
  part('petals_pointy', '花瓣', '尖花瓣', ['flower.petals']),
  part('petals_heart', '花瓣', '心形花瓣', ['flower.petals']),
  // 茎
  part('stem_straight', '茎', '直茎', ['flower.stem']),
  part('stem_curve', '茎', '弯茎', ['flower.stem']),
  // 叶子
  part('leaf_single', '叶子', '单叶', ['flower.leaf']),
  part('leaf_pair', '叶子', '双叶', ['flower.leaf']),
  // ── 冰淇淋（同蛋糕教叠层）──
  // 甜筒
  part('cone_waffle', '甜筒', '华夫筒', ['ice.cone']),
  part('cone_cup', '甜筒', '杯筒', ['ice.cone']),
  // 球
  part('scoop_strawberry', '冰淇淋球', '草莓球', ['ice.scoop']),
  part('scoop_choco', '冰淇淋球', '巧克力球', ['ice.scoop']),
  part('scoop_vanilla', '冰淇淋球', '香草球', ['ice.scoop']),
  // 顶料
  part('ice_cherry', '顶料', '樱桃', ['ice.topping']),
  part('ice_star', '顶料', '小星星糖', ['ice.topping']),
];

/**
 * 统一画风前缀——所有零件图共用这一句，保证「拼起来是一套」（§3.1 美术缝隙靠统一画风压到可接受）。
 * 扁平卡通积木块、粗净黑描边、亮色块、童书简笔、die-cut 无背景、正视居中、无场景无落地影。
 * 每个零件再补一句「本零件长什么样 + 以什么朝向坐进槽」——朝向锁死是关键（轮子必侧看的正圆、
 * 屋顶必是坐在顶上的三角），否则模型每张换个角度，拼进骨架就对不上位姿。
 */
const PART_STYLE =
  'flat 2D cartoon toy building-block piece, thick clean black outline, bright solid childlike colors, ' +
  'simple storybook style, die-cut sticker with fully transparent background, centered, front view, ' +
  'no scene, no ground, no shadow, no text';

/** 每个零件的专属外观 + 坐进槽的朝向（与 PART_LIBRARY 一一对应，partIconPrompt 拼在 PART_STYLE 后）。 */
const PART_SHAPE: Record<string, string> = {
  // 轮子：一律侧看的正圆（能滚的姿态），轮心朝观众
  wheel_round: 'a single round car wheel seen from the side, a perfect circle black tire with a bright hub in the center',
  wheel_star: 'a single round car wheel seen from the side, a perfect circle tire with a yellow star-shaped hub in the center',
  wheel_flower: 'a single round car wheel seen from the side, a perfect circle tire with a pink flower-shaped hub in the center',
  // 车身：横放的车体，顶面平（好坐上零件），侧看
  body_box: 'a boxy rectangular little car body shell seen from the side, flat top, one solid bright color, no wheels',
  body_round: 'a rounded bubble-shaped little car body shell seen from the side, smooth curved top, one solid bright color, no wheels',
  body_truck: 'a chunky pickup-truck cab-and-bed body shell seen from the side, flat cargo bed, one solid bright color, no wheels',
  // 把手：拉着跑的手柄
  handle_curve: 'a single curved pull handle bar, smooth arc shape, one solid color, floating alone',
  handle_straight: 'a single straight upright pull handle bar with a round grip on top, one solid color, floating alone',
  // 墙：正面的一面墙身（房子的躯干），矩形
  wall_brick: 'a front-facing rectangular house wall made of red brick pattern, flat rectangle, no roof, no door',
  wall_wood: 'a front-facing rectangular house wall made of brown wooden planks, flat rectangle, no roof, no door',
  wall_stone: 'a front-facing rectangular house wall made of grey stone blocks, flat rectangle, no roof, no door',
  // 屋顶：坐在墙顶上的盖子，底边平
  roof_tri: 'a triangular pitched house roof, flat bottom edge to sit on a wall, red tiles, roof only',
  roof_flat: 'a flat low house roof slab, flat bottom edge to sit on a wall, one solid color, roof only',
  roof_dome: 'a rounded dome house roof, flat bottom edge to sit on a wall, one solid color, roof only',
  // 门：贴在墙面上的门
  door_arch: 'a single arched top wooden door, rounded top, one solid color, door only',
  door_square: 'a single square wooden door, flat top, one solid color, door only',
  // 窗：贴在墙面上的窗
  window_round: 'a single round porthole window with a cross frame, blue glass, window only',
  window_square: 'a single square window with a cross frame, blue glass, window only',
  // 烟囱：竖在屋顶/车头上的小柱，底边平
  chimney_brick: 'a short upright red brick chimney stack, flat bottom, chimney only',
  chimney_pipe: 'a short upright grey metal pipe chimney, flat bottom, chimney only',
  // 火车头：侧看的车头，前脸朝左
  engine_classic: 'a classic steam train locomotive engine seen from the side, rounded boiler and a little cab, one solid color, no wheels',
  engine_bullet: 'a sleek modern bullet-train nose engine seen from the side, smooth pointed front, one solid color, no wheels',
  // 车厢：侧看的一节车厢
  car_open: 'an open-top train freight wagon seen from the side, rectangular box with no roof, one solid color, no wheels',
  car_closed: 'a closed roofed train carriage seen from the side, rectangular box with a rounded roof, one solid color, no wheels',
  // 雪人雪球：正圆的白雪球
  snowball_big: 'a big round white snowball, a plain soft white circle',
  snowball_big_sparkle: 'a big round white snowball with a few blue sparkle dots on it, a soft white circle',
  snowball_small: 'a small round white snowball, a plain soft white circle',
  snowball_small_sparkle: 'a small round white snowball with a few blue sparkle dots on it, a soft white circle',
  // 帽子：戴在头顶的帽
  hat_top: 'a black top hat with a red band, flat bottom brim to sit on a head, hat only',
  hat_bucket: 'a small metal bucket turned upside-down as a hat, flat bottom rim, one solid color, hat only',
  // 鼻子：贴在脸中间的小件
  nose_carrot: 'a single orange carrot nose pointing sideways, cone shape, nose only',
  nose_button: 'a single round black button nose, a simple dark circle, nose only',
  // 蛋糕胚：横放的一大层饼胚，顶面平（好叠奶油），正视
  base_round: 'a thick round cake sponge base tier seen from the front, a wide short cylinder with a flat top, warm sponge color, cake base only',
  base_square: 'a thick square cake sponge base tier seen from the front, a wide flat-topped block, warm sponge color, cake base only',
  base_heart: 'a thick heart-shaped cake sponge base tier seen from the front, flat top, warm sponge color, cake base only',
  // 奶油层：抹在胚外的一圈奶油带，底边平
  cream_white: 'a band of swirled white whipped cream frosting, a horizontal wavy layer with a flat bottom to sit on a cake, cream only',
  cream_pink: 'a band of swirled pink strawberry cream frosting, a horizontal wavy layer with a flat bottom, cream only',
  cream_choco: 'a band of swirled brown chocolate cream frosting, a horizontal wavy layer with a flat bottom, cream only',
  // 顶料（蛋糕）：点在最上的小果子/糖粒
  top_strawberry: 'a single small red strawberry with green leaves on top, a cute round berry, topping only',
  top_cherry: 'a single small red cherry with a stem, a shiny round berry, topping only',
  top_star: 'a small cluster of a few colorful five-pointed star-shaped candies grouped together, each a distinct bright candy star, NOT a block, candy topping only',
  // 蜡烛：竖在蛋糕顶的小蜡烛，底端平
  candle_one: 'a single thin striped birthday candle with a small yellow flame, standing upright, flat bottom, candle only',
  candle_number: 'a single number-shaped birthday candle with a small yellow flame, standing upright, flat bottom, candle only',
  // 花心：花正中的圆盘，正视
  center_yellow: 'a round flower center disc, a plain yellow circle dotted with tiny pollen specks, flower center only',
  center_orange: 'a round flower center disc, a plain orange circle dotted with tiny pollen specks, flower center only',
  center_dot: 'a round flower center disc, a bright circle covered in small dots, flower center only',
  // 花瓣：围成一圈的花冠（中间留空给花心），正视
  petals_round: 'a ring of rounded soft flower petals arranged in a circle with an empty hole in the middle, bright color, petals only',
  petals_pointy: 'a ring of pointy sharp flower petals arranged in a circle with an empty hole in the middle, bright color, petals only',
  petals_heart: 'a ring of heart-shaped flower petals arranged in a circle with an empty hole in the middle, bright color, petals only',
  // 茎：竖直的绿杆，撑住花，底端平
  stem_straight: 'a straight upright green flower stem, a simple vertical green bar, flat bottom, stem only',
  stem_curve: 'a gently curved green flower stem, a soft S-curve green bar, flat bottom, stem only',
  // 叶子：从茎侧张开的绿叶
  leaf_single: 'a single green leaf pointing sideways, a simple pointed oval, leaf only',
  leaf_pair: 'a pair of green leaves spreading to both sides, two simple pointed ovals, leaves only',
  // 甜筒：尖头朝下的华夫筒/杯，托着球
  cone_waffle: 'a pointed waffle ice-cream cone, a light brown criss-cross cone with the point facing down and an open flat top, cone only',
  cone_cup: 'a small round ice-cream cup, a short tub with an open flat top, one solid color, cup only',
  // 冰淇淋球：圆圆的一坨，坐在筒上
  scoop_strawberry: 'a round scoop of pink strawberry ice cream, a soft ball with a flat bottom, scoop only',
  scoop_choco: 'a round scoop of brown chocolate ice cream, a soft ball with a flat bottom, scoop only',
  scoop_vanilla: 'a round scoop of cream vanilla ice cream, a soft ball with a flat bottom, scoop only',
  // 顶料（冰淇淋）：淋在球顶的小件
  ice_cherry: 'a single small red cherry with a stem, a shiny round berry, topping only',
  ice_star: 'a small cluster of a few colorful five-pointed star-shaped candies grouped together, each a distinct bright candy star, NOT a block, candy topping only',
};

/** 取某零件的生图 prompt（统一画风前缀 + 专属外观；未知回退到中文名兜底）。P3 批量生成管线读它。 */
export function partIconPrompt(id: string): string {
  const shape = PART_SHAPE[id];
  const part = PART_BY_ID.get(id);
  if (!shape) return `${PART_STYLE}, a cute ${part?.name ?? id}`;
  return `${PART_STYLE}, ${shape}`;
}

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
