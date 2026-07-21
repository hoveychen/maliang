/**
 * 物品实体：内置 seed + 地形矩阵的语义校验/派生占用（纯函数）。
 * 设计见 docs/scene-item-refactor-design.md。
 *
 * 内置定义是代码常量而非 DB seed 行——render_ref 与客户端 preload 映射表必须
 * 联动改，本质是代码契约；语音造物才落 items 表（persistence.ts）。
 * 语义（footprint/blocking/wander）逐项迁自客户端硬编码表
 * （scripts/chunk_manager.gd 的 LANDMARKS/SDF_PROPS/散布种类），迁完后客户端表删除。
 *
 * 占地约定（与客户端 _spawn_on_tile 的 reserve 语义对齐）：
 * footprint 奇数边、锚点居中——3×3 即旧 reserve=1。环面 wrap 由取模兜底。
 */

import type { ItemDef, } from './types.ts';
import type { SdfPropSpec } from './sdf_prop.ts';
import type { ComposedSpec } from './build_blueprints.ts';
import { scaleToSize } from './creation_options.ts';
import { T_PATH, T_WATER, TerrainFormatError, argYawDeg, type Terrain } from './terrain.ts';

/** 内置物品定义（≈22 行）。顺序即村庄 palette 的习惯顺序，无语义。 */
export const BUILTIN_ITEMS: readonly ItemDef[] = [
  // 散布布景：SDF 烘焙棉花糖树/灌木（MultiMesh 合批）
  builtin('tree_puff_a', '蓬蓬树·甲', 'baked:tree_puff_a', 1, true),
  builtin('tree_puff_b', '蓬蓬树·乙', 'baked:tree_puff_b', 1, true),
  builtin('tree_puff_c', '蓬蓬树·丙', 'baked:tree_puff_c', 1, true),
  builtin('bush_puff', '圆灌木', 'baked:bush_puff', 1, true),
  // 散布布景：KayKit 石/草丛（草丛可穿行，不占位）
  builtin('rock_0', '岩石·甲', 'kaykit:rock_0', 1, true),
  builtin('rock_1', '岩石·乙', 'kaykit:rock_1', 1, true),
  builtin('rock_2', '岩石·丙', 'kaykit:rock_2', 1, true),
  { ...builtin('tuft_0', '草丛·甲', 'kaykit:tuft_0', 1, false) },
  { ...builtin('tuft_1', '草丛·乙', 'kaykit:tuft_1', 1, false) },
  // 村庄地标建筑（3×3 = 旧 reserve=1）
  builtin('house_0', '蓝顶民居', 'kaykit:house_0', 3, true),
  builtin('house_1', '红顶民居', 'kaykit:house_1', 3, true),
  builtin('house_2', '黄顶民居', 'kaykit:house_2', 3, true),
  builtin('house_3', '绿顶民居', 'kaykit:house_3', 3, true),
  { ...builtin('well', '水井', 'kaykit:well', 3, true), pathOk: true }, // 地标特批压路（坐镇广场）
  builtin('windmill', '风车', 'kaykit:windmill', 3, true),
  // SDF 可动物件（打包内 spec，wander 为围绕锚点的游走半径）
  { ...builtin('walking_hut', '走路小屋', 'sdf_res:walking_hut', 3, true), wander: 1.6 },
  { ...builtin('hop_mailbox', '蹦跳信箱', 'sdf_res:hop_mailbox', 3, true), wander: 1.2 },
  builtin('nodding_flower', '点头花', 'sdf_res:nodding_flower', 1, true),
  builtin('pinwheel', '纸风车', 'sdf_res:pinwheel', 1, true),
  builtin('paper_note', '纸条', 'sdf_res:paper_note', 1, true),
  builtin('crayon', '蜡笔', 'sdf_res:crayon', 1, true),
  builtin('village_sign', '村口路牌', 'sdf_res:village_sign', 1, true),
  // 绿野仙踪（s1-oz）专属布景 prop
  builtin('corn_stalk', '玉米秆', 'sdf_res:corn_stalk', 1, true),

  // ── 未来机器人主题（world-themes P2 打样；全 CC0：Quaternius 机器人 + Kenney Space Kit）──
  // 机器人（Quaternius，assets/scifi/robots/*.glb）
  scifi('robot_animated', '机器人', 'scifi:robot_animated', 3, true),
  scifi('robot_enemy', '守卫机器人', 'scifi:robot_enemy', 3, true),
  scifi('robot_flying', '飞行机器人', 'scifi:robot_flying', 1, true),
  scifi('robot_legs_gun', '巡逻机器人', 'scifi:robot_legs_gun', 3, true),
  scifi('robot_flying_gun', '哨戒机', 'scifi:robot_flying_gun', 1, true),
  scifi('robot_large', '大型机器人', 'scifi:robot_large', 3, true),
  scifi('mech', '机甲', 'scifi:mech', 3, true),
  // 科幻环境物（Kenney Space Kit，assets/scifi/props/*.glb）
  scifi('scifi_hangar', '机库', 'scifi:hangar_smallA', 3, true),
  scifi('scifi_generator', '发电机', 'scifi:machine_generatorLarge', 3, true),
  scifi('scifi_satellite', '卫星天线', 'scifi:satelliteDish_large', 3, true),
  scifi('scifi_barrel', '燃料桶', 'scifi:barrel', 1, true),
  scifi('scifi_crystals', '能量晶簇', 'scifi:rock_crystals', 1, true),

  // ── 玩具房间主题（world-themes P4；全 CC0：Kenney Furniture Kit）──
  // renderRef 'furniture:<Kenney 原名>' → 客户端 assets/packs/toyroom/pack.json（node 类）
  themed('toy_bear', '玩具熊', 'furniture:bear', 1, true, ['toyroom']),
  themed('toy_bed_single', '单人床', 'furniture:bedSingle', 3, true, ['toyroom']),
  themed('toy_bed_bunk', '双层床', 'furniture:bedBunk', 3, true, ['toyroom']),
  themed('toy_bookcase', '书架', 'furniture:bookcaseOpen', 1, true, ['toyroom']),
  themed('toy_sofa', '沙发', 'furniture:loungeSofa', 3, true, ['toyroom']),
  themed('toy_chair', '圆背椅', 'furniture:chairRounded', 1, true, ['toyroom']),
  themed('toy_table', '桌子', 'furniture:table', 3, true, ['toyroom']),
  themed('toy_coffee_table', '茶几', 'furniture:tableCoffee', 1, true, ['toyroom']),
  themed('toy_lamp', '落地灯', 'furniture:lampRoundFloor', 1, true, ['toyroom']),
  themed('toy_plant', '盆栽', 'furniture:pottedPlant', 1, true, ['toyroom']),
  themed('toy_tv', '电视机', 'furniture:televisionModern', 1, true, ['toyroom']),
  themed('toy_box', '纸箱', 'furniture:cardboardBoxOpen', 1, true, ['toyroom']),

  // ── 现代城市主题（world-themes P4；全 CC0：Kenney City Kit Commercial）──
  // renderRef 'city:<Kenney 原名>' → 客户端 assets/packs/city/pack.json（node 类）
  themed('city_shop_a', '临街商铺·甲', 'city:building-a', 3, true, ['city']),
  themed('city_shop_b', '临街商铺·乙', 'city:building-b', 3, true, ['city']),
  themed('city_shop_c', '临街商铺·丙', 'city:building-c', 3, true, ['city']),
  themed('city_shop_d', '临街商铺·丁', 'city:building-d', 3, true, ['city']),
  themed('city_shop_e', '临街商铺·戊', 'city:building-e', 3, true, ['city']),
  themed('city_shop_f', '临街商铺·己', 'city:building-f', 3, true, ['city']),
  themed('city_shop_g', '临街商铺·庚', 'city:building-g', 3, true, ['city']),
  themed('city_tower_a', '高楼·甲', 'city:building-skyscraper-a', 3, true, ['city']),
  themed('city_tower_b', '高楼·乙', 'city:building-skyscraper-b', 3, true, ['city']),
  themed('city_tower_c', '高楼·丙', 'city:building-skyscraper-c', 3, true, ['city']),
  themed('city_tower_d', '高楼·丁', 'city:building-skyscraper-d', 3, true, ['city']),
  themed('city_tower_e', '高楼·戊', 'city:building-skyscraper-e', 3, true, ['city']),

  // ── 厨房主题（world-themes P4；全 CC0：同 Kenney Furniture Kit 的厨电子集）──
  // renderRef 'kitchen:<Kenney 原名>' → 客户端 assets/packs/kitchen/pack.json（node 类）
  themed('kit_fridge', '冰箱', 'kitchen:kitchenFridge', 1, true, ['kitchen']),
  themed('kit_stove', '灶台', 'kitchen:kitchenStove', 1, true, ['kitchen']),
  themed('kit_sink', '水槽', 'kitchen:kitchenSink', 1, true, ['kitchen']),
  themed('kit_microwave', '微波炉', 'kitchen:kitchenMicrowave', 1, true, ['kitchen']),
  themed('kit_cabinet', '橱柜', 'kitchen:kitchenCabinet', 1, true, ['kitchen']),
  themed('kit_cabinet_drawer', '抽屉柜', 'kitchen:kitchenCabinetDrawer', 1, true, ['kitchen']),
  themed('kit_coffee', '咖啡机', 'kitchen:kitchenCoffeeMachine', 1, true, ['kitchen']),
  themed('kit_blender', '榨汁机', 'kitchen:kitchenBlender', 1, true, ['kitchen']),
  themed('kit_toaster', '烤面包机', 'kitchen:toaster', 1, true, ['kitchen']),
  themed('kit_hood', '抽油烟机', 'kitchen:hoodModern', 1, true, ['kitchen']),
  themed('kit_bar', '吧台', 'kitchen:kitchenBar', 1, true, ['kitchen']),
  themed('kit_stool', '吧凳', 'kitchen:stoolBar', 1, true, ['kitchen']),

  // ── 中世纪小镇主题（world-themes P4；全 CC0：KayKit Medieval Hexagon，与基础村庄同画风）──
  // renderRef 'medieval:<KayKit 原名>' → 客户端 assets/packs/medieval_town/pack.json（node 类）
  themed('mv_home_a', '民居·甲', 'medieval:building_home_A_blue', 3, true, ['medieval_town']),
  themed('mv_home_b', '民居·乙', 'medieval:building_home_B_blue', 3, true, ['medieval_town']),
  themed('mv_blacksmith', '铁匠铺', 'medieval:building_blacksmith_blue', 3, true, ['medieval_town']),
  themed('mv_market', '集市', 'medieval:building_market_blue', 3, true, ['medieval_town']),
  themed('mv_tavern', '酒馆', 'medieval:building_tavern_blue', 3, true, ['medieval_town']),
  themed('mv_church', '教堂', 'medieval:building_church_blue', 3, true, ['medieval_town']),
  themed('mv_windmill', '风车', 'medieval:building_windmill_blue', 3, true, ['medieval_town']),
  themed('mv_watermill', '水车', 'medieval:building_watermill_blue', 3, true, ['medieval_town']),
  themed('mv_lumbermill', '伐木场', 'medieval:building_lumbermill_blue', 3, true, ['medieval_town']),
  themed('mv_mine', '矿场', 'medieval:building_mine_blue', 3, true, ['medieval_town']),
  themed('mv_well', '水井', 'medieval:building_well_blue', 3, true, ['medieval_town']),

  // ── 中世纪王国主题（world-themes P4；全 CC0：KayKit Medieval Hexagon 军事 + Medieval Builder 城防）──
  themed('mk_castle', '城堡', 'medieval:building_castle_blue', 5, true, ['medieval_kingdom']),
  themed('mk_barracks', '兵营', 'medieval:building_barracks_blue', 3, true, ['medieval_kingdom']),
  themed('mk_archery', '箭馆', 'medieval:building_archeryrange_blue', 3, true, ['medieval_kingdom']),
  themed('mk_tower_a', '塔楼·甲', 'medieval:building_tower_A_blue', 3, true, ['medieval_kingdom']),
  themed('mk_tower_b', '塔楼·乙', 'medieval:building_tower_B_blue', 3, true, ['medieval_kingdom']),
  themed('mk_tower_base', '塔基', 'medieval:building_tower_base_blue', 3, true, ['medieval_kingdom']),
  themed('mk_catapult', '投石塔', 'medieval:building_tower_catapult_blue', 3, true, ['medieval_kingdom']),
  themed('mk_gate', '城门', 'medieval:wall_gate', 3, true, ['medieval_kingdom']),
  themed('mk_gate_closed', '闭合城门', 'medieval:wall_gate_closed', 3, true, ['medieval_kingdom']),
  themed('mk_wall', '城墙', 'medieval:wall_straight', 3, true, ['medieval_kingdom']),
  themed('mk_wall_corner', '城墙拐角', 'medieval:wall_corner', 3, true, ['medieval_kingdom']),
  themed('mk_watchtower', '瞭望塔', 'medieval:watchtower', 3, true, ['medieval_kingdom']),

  // ── 海底主题（world-themes P5 半覆盖；全 CC0：Quaternius Animated Fish）──
  // renderRef 'underwater:<key>' → 客户端 assets/packs/underwater/pack.json（node 类）。
  // 地面走 P1 tile 地基 T_SAND(沙地)+T_WATER(水体)。小鱼 1×1，大型生物 3×3。
  themed('sea_fish_a', '小鱼·甲', 'underwater:fish_a', 1, true, ['underwater']),
  themed('sea_fish_b', '小鱼·乙', 'underwater:fish_b', 1, true, ['underwater']),
  themed('sea_fish_c', '热带鱼', 'underwater:fish_c', 3, true, ['underwater']),
  themed('sea_dolphin', '海豚', 'underwater:dolphin', 3, true, ['underwater']),
  themed('sea_whale', '鲸鱼', 'underwater:whale', 3, true, ['underwater']),
  themed('sea_manta', '蝠鲼', 'underwater:manta', 3, true, ['underwater']),
  themed('sea_shark', '鲨鱼', 'underwater:shark', 3, true, ['underwater']),

  // ── 冰雪世界主题（world-themes P5 半覆盖；全 CC0：Kenney Holiday Kit）──
  // renderRef 'winter:<key>' → 客户端 assets/packs/winter/pack.json（node 类）。
  // 地面走 P1 tile 地基 T_SNOW(雪地)。雪堆非阻挡点缀（pathOk 无关，blocking=false）。
  themed('snow_snowman', '雪人', 'winter:snowman', 3, true, ['winter']),
  themed('snow_snowman_hat', '戴帽雪人', 'winter:snowman_hat', 3, true, ['winter']),
  themed('snow_tree_a', '雪松·甲', 'winter:tree_snow_a', 3, true, ['winter']),
  themed('snow_tree_b', '雪松·乙', 'winter:tree_snow_b', 3, true, ['winter']),
  themed('snow_tree_c', '雪松·丙', 'winter:tree_snow_c', 3, true, ['winter']),
  themed('snow_tree_lit', '装饰雪树', 'winter:tree_decorated_snow', 3, true, ['winter']),
  themed('snow_reindeer', '驯鹿', 'winter:reindeer', 3, true, ['winter']),
  themed('snow_sled', '雪橇', 'winter:sled', 3, true, ['winter']),
  themed('snow_pile', '雪堆', 'winter:snow_pile', 1, false, ['winter']),
  themed('snow_present_a', '礼物盒·方', 'winter:present_a', 1, true, ['winter']),
  themed('snow_present_b', '礼物盒·圆', 'winter:present_b', 1, true, ['winter']),
  themed('snow_nutcracker', '胡桃夹子', 'winter:nutcracker', 1, true, ['winter']),

  // ── 医院主题（world-themes P5 半覆盖；全 CC0：Kenney Furniture Kit 拼装）──
  // renderRef 'hospital:<key>' → 客户端 assets/packs/hospital/pack.json（node 类）。
  // 地面走 P1 tile 地基 T_TILE(瓷砖)。无现成 CC0 医疗包，老板拍板用家具拼病房/诊室
  // （Atomic Realm 医院包因禁再分发、与本仓库 PUBLIC 冲突而弃用，见 SOURCES.txt）。
  themed('hosp_bed', '病床', 'hospital:wardBed', 3, true, ['hospital']),
  themed('hosp_bed_wide', '双人病床', 'hospital:wardBedWide', 3, true, ['hospital']),
  themed('hosp_bedside', '床头柜', 'hospital:bedside', 1, true, ['hospital']),
  themed('hosp_visitor_chair', '陪护椅', 'hospital:visitorChair', 1, true, ['hospital']),
  themed('hosp_wait_bench', '候诊椅', 'hospital:waitBench', 1, true, ['hospital']),
  themed('hosp_nurse_desk', '护士站', 'hospital:nurseDesk', 3, true, ['hospital']),
  themed('hosp_doc_chair', '医生椅', 'hospital:docChair', 1, true, ['hospital']),
  themed('hosp_sink', '洗手池', 'hospital:handSink', 1, true, ['hospital']),
  themed('hosp_med_cabinet', '药品柜', 'hospital:medCabinet', 1, true, ['hospital']),
  themed('hosp_supply_cabinet', '器械柜', 'hospital:supplyCabinet', 1, true, ['hospital']),
  themed('hosp_waste_bin', '医疗垃圾桶', 'hospital:wasteBin', 1, true, ['hospital']),
  themed('hosp_floor_lamp', '落地灯', 'hospital:floorLamp', 1, true, ['hospital']),

  // ── 罗马主题（world-themes P6 硬缺口；全 CC0：复用已装 KayKit 石件近似）──
  // 老板拍板无 CC0 罗马包→用中世纪石塔/石墙/拱门近似，renderRef 'roman:<key>' 指向
  // assets/medieval/ 同一 glb（零新资产）。见 assets/packs/roman/pack.json。不地道但保画风。
  themed('roman_arch', '拱门', 'roman:roman_arch', 3, true, ['roman']),
  themed('roman_wall', '石墙', 'roman:roman_wall', 3, true, ['roman']),
  themed('roman_wall_corner', '石墙拐角', 'roman:roman_wall_corner', 3, true, ['roman']),
  themed('roman_watchtower', '哨塔', 'roman:roman_watchtower', 3, true, ['roman']),
  themed('roman_tower', '石塔', 'roman:roman_tower', 3, true, ['roman']),
  themed('roman_tower_b', '瞭望石塔', 'roman:roman_tower_b', 3, true, ['roman']),
  themed('roman_column_base', '石柱基', 'roman:roman_column_base', 3, true, ['roman']),
  themed('roman_fort', '罗马要塞', 'roman:roman_fort', 5, true, ['roman']),

  // ── 中国古代主题（world-themes P6 硬缺口；CC-BY+CC0 东方古建散件拼凑）──
  // 老板拍板：无 CC0 中式包（CS Studio 禁再分发），用 poly.pizza CC-BY/CC0 散件
  // （CC-BY 允许再分发只需署名）。薄主题 4 件、画风混杂，CC-BY 作者须记入 P7 署名页。
  // 见 assets/ancient_china/SOURCES.txt。renderRef 'ancient_china:<key>'。
  themed('cn_pagoda', '宝塔', 'ancient_china:pagoda', 3, true, ['ancient_china']),
  themed('cn_archway', '牌坊', 'ancient_china:torii', 3, true, ['ancient_china']),
  themed('cn_pavilion', '古亭', 'ancient_china:shrine_a', 3, true, ['ancient_china']),
  themed('cn_shrine', '神龛', 'ancient_china:shrine_b', 3, true, ['ancient_china']),

  // ── 侏罗纪时代主题（world-themes 补遗第 12 主题；全 CC0：Quaternius Animated Dinosaurs）──
  // renderRef 'dino:<key>' → 客户端 assets/packs/dino/pack.json（node 类）。全 3×3。
  // 地面可搭配 P1 tile 地基（草地/沙地）。物种按 AABB 形状匹配，见 assets/dino/SOURCES.txt。
  themed('dino_trex', '霸王龙', 'dino:trex', 3, true, ['jurassic']),
  themed('dino_raptor', '迅猛龙', 'dino:raptor', 3, true, ['jurassic']),
  themed('dino_triceratops', '三角龙', 'dino:triceratops', 3, true, ['jurassic']),
  themed('dino_parasaur', '鸭嘴龙', 'dino:parasaur', 3, true, ['jurassic']),
  themed('dino_stego', '剑龙', 'dino:stego', 3, true, ['jurassic']),
  themed('dino_apato', '腕龙', 'dino:apato', 3, true, ['jurassic']),

  // ── 贴纸系列（挂 tile 边缘的薄片，docs/sticker-items-design.md）：不占位不阻挡，
  // 小红花商店购买进背包，允许拾回（贴错能揭下来）。──
  sticker('sticker_sun', '太阳贴纸'),
  sticker('sticker_flower', '花朵贴纸'),
  sticker('sticker_star', '星星贴纸'),
  sticker('sticker_rainbow', '彩虹贴纸'),
  sticker('sticker_heart', '爱心贴纸'),
  sticker('sticker_butterfly', '蝴蝶贴纸'),
  sticker('sticker_moon', '月亮贴纸'),
  sticker('sticker_cloud', '云朵贴纸'),
  sticker('sticker_strawberry', '草莓贴纸'),
  sticker('sticker_smile', '笑脸贴纸'),
  sticker('sticker_flag', '小旗贴纸'),
  sticker('sticker_mushroom', '蘑菇贴纸'),
  // ── 剧情纪念贴纸（M2《三只小猪》）：只随幕奖励发放（story 结算 bagAdd），小铺不卖——
  // 纪念感的前提是买不到。renderRef 'sticker:story_*' → assets/stickers/story_*.webp（客户端打包）。──
  { ...sticker('story_straw', '草垛纪念贴纸'), souvenir: true },
  { ...sticker('story_plank', '木板纪念贴纸'), souvenir: true },
  { ...sticker('story_brick', '砖房纪念贴纸'), souvenir: true },
  // ── 剧情纪念贴纸（第一季册 2《小红帽》）──
  { ...sticker('story_basket', '点心篮纪念贴纸'), souvenir: true },
  // ── 剧情纪念贴纸（第一季册 5《绿野仙踪》）──
  { ...sticker('story_ruby', '红宝石鞋纪念贴纸'), souvenir: true },
  { ...sticker('story_emerald', '翡翠城纪念贴纸'), souvenir: true },
];

function builtin(id: string, name: string, renderRef: string, span: number, blocking: boolean): ItemDef {
  return { id, worldId: null, name, renderRef, footprintW: span, footprintH: span, blocking, pathOk: false, wander: 0 };
}

/** 主题布景（带 themes 软标签；语义同 builtin，仅多一个分类标签，供造世界引导按主题过滤）。 */
function themed(id: string, name: string, renderRef: string, span: number, blocking: boolean, themes: string[]): ItemDef {
  return { id, worldId: null, name, renderRef, footprintW: span, footprintH: span, blocking, pathOk: false, wander: 0, themes };
}

/** 未来机器人主题便捷封装（themes 恒为 ['scifi']）。 */
function scifi(id: string, name: string, renderRef: string, span: number, blocking: boolean): ItemDef {
  return themed(id, name, renderRef, span, blocking, ['scifi']);
}

/** 贴纸：mount:'edge' 薄片，footprint/blocking/wander 对边缘物无意义（恒 1×1/false/0）。 */
function sticker(id: string, name: string): ItemDef {
  return { ...builtin(id, name, `sticker:${id.replace(/^sticker_/, '')}`, 1, false), pathOk: true, mount: 'edge' };
}

/**
 * 语音造物的实体行（spec 内联进 items 表）。占地默认 1×1（旧动态物件同款），
 * 但 big 体型档（scale≈1.4）的造物 +1 环 → 3×3，让大物件脚下占更多格、挡路更真实
 * （prop-size；footprint 须奇数边、锚点居中，见本文件顶部约定）。small/medium 保持 1×1 避免 0 格。
 * pathOk=true——孩子把玩具摆在路上是常态，不拦；wander 与客户端 _prop_wander 同款推导。
 */
export function creationItemDef(worldId: string, id: string, spec: SdfPropSpec): ItemDef {
  const span = scaleToSize(spec.scale) === 'big' ? 3 : 1;
  return {
    id,
    worldId,
    name: spec.name || '小宝贝',
    renderRef: 'sdf_inline',
    spec,
    footprintW: span,
    footprintH: span,
    blocking: true,
    pathOk: true,
    wander: spec.locomotion && spec.locomotion.type !== 'none' ? 1.2 : 0,
  };
}

/**
 * 造贴纸的实体行（fairy-stickers）：与内置 sticker() 同为 mount:'edge' 薄片，但贴图来自网络资产哈希
 * 而非打包资源——renderRef 用 `sticker:@<hash>` 约定（内置是 `sticker:<name>`）。客户端边缘/角色锚点
 * 取图路径见 skey 是否以 '@' 打头分流（打包 load_resource vs api.fetch_texture）。
 * footprint/blocking/wander 对边缘物无意义（恒 1×1/false/0），与内置贴纸一致。
 */
export function creationStickerDef(worldId: string, id: string, name: string, assetHash: string): ItemDef {
  return {
    id,
    worldId,
    name: name || '贴纸',
    renderRef: `sticker:@${assetHash}`,
    footprintW: 1,
    footprintH: 1,
    blocking: false,
    pathOk: true,
    wander: 0,
    mount: 'edge',
  };
}

/**
 * 积木式造物的实体行（B1，docs/kids-thinking-build-from-parts.md §3.1）：renderRef='composed:'，
 * spec 存「骨架 + 零件树」（ComposedSpec），永久保留可拆改结构，绝不拍平成一张图。
 * 摆放/拾取/背包全走 items 现成通路（万物皆物品）；客户端 ComposedProp 渲染器（P4）读 spec 画多片子 quad。
 * footprint 3×3（放大一档，与 big 造物同档、奇数边锚点居中）：拼的房子要有「盖了一栋房」的分量
 * （曾 1×1，落地只有一格贴纸大小，与 M2 尾声叙事不匹配）。只影响新落成——存量 items 行不变。
 * 组合物挡路、可压路面（与造物 createPropAsync 同档）。
 */
export function creationBuildDef(worldId: string, id: string, name: string, spec: ComposedSpec): ItemDef {
  return {
    id,
    worldId,
    name: name || '拼装作品',
    renderRef: 'composed:',
    spec,
    footprintW: 3,
    footprintH: 3,
    blocking: true,
    pathOk: true,
    wander: 0,
  };
}

const BUILTIN_BY_ID = new Map(BUILTIN_ITEMS.map((d) => [d.id, d]));

export function getBuiltinItem(id: string): ItemDef | undefined {
  return BUILTIN_BY_ID.get(id);
}

/** 实体解析器：palette id → 定义。内置查常量表，造物由调用方接 items 表。 */
export type ItemResolver = (id: string) => ItemDef | undefined;

/** 只认内置（导出工具产的初始矩阵、无造物场景用）。 */
export const resolveBuiltin: ItemResolver = (id) => BUILTIN_BY_ID.get(id);

/** footprint 锚点居中展开的原点（奇数边居中；偶数边偏西北，当前无此形状）。 */
export function footprintOrigin(x: number, y: number, w: number, h: number): [number, number] {
  return [x - ((w - 1) >> 1), y - ((h - 1) >> 1)];
}

/** 朝向旋转后的 footprint 尺寸（就近象限，90°/270° 交换宽高；当前全方形，恒等）。 */
export function rotatedFootprint(def: ItemDef, arg: number): [number, number] {
  const quadrant = Math.round(argYawDeg(arg) / 90) % 4;
  return quadrant === 1 || quadrant === 3 ? [def.footprintH, def.footprintW] : [def.footprintW, def.footprintH];
}

/**
 * 从矩阵派生静态占用位图（tile 分辨率，1=被 blocking 物品 footprint 覆盖）。
 * 客户端 TerrainMap 的派生占用与此逐字节对齐（P4 参照实现）。
 * 语义非法（引用无法解析/占地冲突/压水…）直接抛——派生与校验是同一次遍历。
 */
export function buildStaticOccupancy(t: Terrain, resolve: ItemResolver): Uint8Array {
  const n = t.gridW * t.gridH;
  const occ = new Uint8Array(n);
  // 环面 wrap 按本地形的实际边长——不同尺寸场景 footprint 跨界回绕才对齐（方形，W=H）
  const wrap = (v: number) => ((v % t.gridW) + t.gridW) % t.gridW;

  // palette 全部可解析（未被引用的空悬 palette 项也算错——palette 该压实）
  const defs: ItemDef[] = t.palette.map((id) => {
    const def = resolve(id);
    if (!def) throw new TerrainFormatError(`palette item ${JSON.stringify(id)} 无法解析`);
    return def;
  });

  for (let i = 0; i < n; i++) {
    const ref = t.itemRef[i]!;
    if (ref === 0) continue;
    const def = defs[ref - 1]!;
    const ax = i % t.gridW;
    const ay = Math.floor(i / t.gridW);

    // 边缘物（贴纸）不许挂 tile 正上方——mount 错位是数据损坏
    if (def.mount === 'edge') throw new TerrainFormatError(`edge 物品 ${def.id} at (${ax},${ay}) 挂在 itemRef`);

    // 非 blocking（草丛类）：纯点缀，只禁水面，不占位
    if (!def.blocking) {
      if (t.types[i] === T_WATER) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 落在水面`);
      continue;
    }

    const [w, h] = rotatedFootprint(def, t.itemArg[i]!);
    const [ox, oy] = footprintOrigin(ax, ay, w, h);
    const anchorHeight = t.heights[i]!;
    for (let dy = 0; dy < h; dy++) {
      for (let dx = 0; dx < w; dx++) {
        const j = wrap(oy + dy) * t.gridW + wrap(ox + dx);
        const ty = t.types[j]!;
        if (ty === T_WATER) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地覆盖水面`);
        if (ty === T_PATH && !def.pathOk) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地压路`);
        if (t.heights[j] !== anchorHeight) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地跨台阶`);
        if (occ[j]) throw new TerrainFormatError(`item ${def.id} at (${ax},${ay}) 占地与他物冲突`);
        occ[j] = 1;
      }
    }
  }
  return occ;
}

/**
 * 矩阵的物品语义校验（入库/编辑前守门）：palette 可解析、footprint 不压水/
 * 不压路（除非 pathOk）/不跨台阶/互不重叠。edge 平面（贴纸等薄片）只做引用
 * 合法性校验：可解析且 mount==='edge'，不参与占用（sticker-items 设计 §1.1）。
 */
export function validateTerrainItems(t: Terrain, resolve: ItemResolver = resolveBuiltin): void {
  for (let e = 0; e < 4; e++) {
    const plane = t.edges[e]!;
    for (let i = 0; i < plane.length; i++) {
      const ref = plane[i]!;
      if (ref === 0) continue;
      const id = t.palette[ref - 1];
      const def = id !== undefined ? resolve(id) : undefined;
      if (!def) throw new TerrainFormatError(`edge[${e}][${i}] 引用 ${ref} 无法解析`);
      if (def.mount !== 'edge') throw new TerrainFormatError(`tile 物品 ${def.id} 挂在 edge[${e}][${i}]`);
    }
  }
  buildStaticOccupancy(t, resolve);
}
