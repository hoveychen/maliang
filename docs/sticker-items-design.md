# 贴纸物品设计：tile 边缘悬挂（sticker-items）

> 状态：定稿（2026-07-12，开放问题老板已拍板，见 §5）。
> 目标一句话：新增**贴纸**这一类薄片物品——一张带白描边的贴纸图，孩子可以把它**挂在任意 tile 的四条边缘**上
> （村口挂个太阳、台阶侧面贴朵花），后续同一套贴纸还能**贴到角色身上**（见姊妹篇
> [character-anchors-design.md](character-anchors-design.md)）。
> 本篇只覆盖 tile 边缘这一半；两篇共用同一个贴纸物品目录。

## 0. 为什么现在做是顺路活（已核实的现状）

scene-items 大修时老板已拍板"**tile 四面边缘挂载：数据位一期就留，渲染二期**"
（[scene-item-refactor-design.md](scene-item-refactor-design.md) 约束 6）。数据层**已经全部存在**：

- 矩阵 v2 含 4 张边缘平面 `edgeN/E/S/W u8[75×75]`，palette 索引，当前恒 0
  （[server/src/terrain.ts:21,67-68](../server/src/terrain.ts#L67-L68)）；
- 客户端 `TerrainMap` 已解析并持有这 4 张平面，`EDGE_N..EDGE_W` 常量与服务端一一对应
  （[scripts/terrain_map.gd:50-54,111](../scripts/terrain_map.gd#L50-L54)）；
- patch 协议在 scene-items 设计里已画好 edge 的形状：`edits:[{x, y, edge?: [side, refIndex]}]`
  （设计文档 §162 行，**尚未实现**）。

**真正缺的只有三段**：① `terrain_edit.ts` 编辑通路不认 edge（grep 无 edge，已核实）；
② `chunk_manager.gd` 没有边缘渲染分支；③ 没有贴纸这类物品实体与资产。
本设计就是把"渲染二期"做掉，并以贴纸作为第一种边缘物品。

## 1. 贴纸物品实体

### 1.1 ItemDef 扩展：`mount` 字段

```ts
// server/src/types.ts ItemDef 增加：
mount?: 'tile' | 'edge';   // 缺省 'tile'（存量语义不变）
```

- `mount:'edge'` 的物品**只能**挂边缘平面，不进 `itemRef`；反之亦然。
  `editSceneTerrain` 校验时按 mount 拒绝错位摆放。
- 边缘物品**不进占用位图**：`buildStaticOccupancy` 跳过 edge 平面
  （薄片贴在边上，不挡走路——与约束"blocking 对边缘物无意义"一致）。
- footprint 对边缘物品无意义，恒 1×1；`wander` 恒 0。

### 1.2 内置贴纸系列（第一批 ~12 张）

```ts
// items.ts BUILTIN_ITEMS 追加（renderRef 新前缀 sticker:）：
stickerBuiltin('sticker_sun',    '太阳贴纸',   'sticker:sun'),
stickerBuiltin('sticker_flower', '花朵贴纸',   'sticker:flower'),
stickerBuiltin('sticker_star',   '星星贴纸',   'sticker:star'),
// … 彩虹/爱心/蝴蝶/月亮/云朵/草莓/笑脸/小旗/蘑菇
```

- 贴纸图资产走**客户端打包**（`res://assets/stickers/<name>.webp`），与 `sdf_res:` 同型——
  内置定义是代码契约，服务端 renderRef 与客户端 preload 表联动改（items.ts 现有注释同款约定）。
- 生成管线复用**造角色图标**那套（prod `/admin/creation-icons` 先例 + `addStickerBorder`
  白描边贴纸风，[chroma_cutout.ts](../server/src/adapters/chroma_cutout.ts)）：统一画风批量生成
  → 抠图 → 白描边 → trim → WebP 入库。角色立绘本来就是贴纸风白描边，视觉语言现成。
- **暂不做语音造贴纸**（AIGC 即时生成、走 `sticker_asset:<hash>` 服务端资产引用）——
  renderRef 前缀语法预留，二期再议。

### 1.3 arg 语义（边缘平面要不要参数位）

scene-items 设计已明确"边缘物品的参数平面留给 v3；边缘物世界高度默认取所在 tile height"。
**沿用该决定**：本期边缘只有 palette 索引一个字节，无 yaw/无高度参数——
贴纸朝向由所在边决定（法线朝外），不需要 arg。

## 2. 协议与编辑通路

### 2.1 `terrain_edit.ts`：edits 增加 edge

```ts
// TileEdit / AppliedEdit 增加：
edge?: [side: 0|1|2|3, ref: number] | null;   // ref=palette 索引+1，0 语义同 item（null=清除）
```

- 校验：ref 解析出的实体必须 `mount==='edge'`；side∈[0,3]；同一边已有贴纸 = 覆写（与 item 对齐）。
- `terrain_patch` 广播原样带 edge 字段；`version+1` 机制不变。
- **注意与 scene-items 设计 §162 的形状保持一致**（`edge:[side,refIndex]`），别发明新形状。

### 2.2 WS 消息：复用 item_place / item_pickup

```
item_place  { …现有字段, edgeSide?: 0|1|2|3 }   // 带 edgeSide = 摆边缘（贴纸），不带 = 摆 tile（存量）
item_pickup { …现有字段, edgeSide?: 0|1|2|3 }
```

- 服务端 handler（[server.ts:2030-2082](../server/src/server.ts#L2030-L2082)）按 edgeSide 分流到
  edge 编辑；背包扣/加、`bag_update` 回执逻辑照旧——**贴纸在背包里就是普通物品**。
- 摆放校验从"tile 为空"换成"该边为空"；拾取校验从 `def.worldId===null` 拒拾改为：
  **内置贴纸允许拾回**（孩子贴错了要能揭下来；树/建筑拒拾的理由是防拆村庄，贴纸无此风险）。
  现行规则相应缩小为"mount:'tile' 的内置物拒拾"（老板已确认，2026-07-12）。

### 2.3 获取：小红花商店（老板拍板 2026-07-12）

贴纸经**小红花购买**进背包——给钱包经济（reward-flower）新增第一个持续性消费出口
（现有唯一扣费点是造角色）：

- WS 新消息 `sticker_buy { worldId, itemId }`：服务端校验是内置贴纸 + 钱包余额够
  （单价建议 1 朵/张，走现有 wallet 扣减路径）→ `bagAdd` → 回 `bag_update` + `wallet_update`。
- 客户端入口：手机**物品页内嵌"贴纸小铺"栏**（不新开 app，物品页 tab/分区即可）——
  列出全部内置贴纸 + 价格，点选购买；余额不足给仙子语音提示（复用 gen_denied 同款文案通道）。

### 2.4 摆放 UX（客户端）

- 背包（手机物品页）点贴纸 → 落到**玩家当前朝向的相邻 tile 的近侧边**
  （即贴在孩子面前，面向孩子）；该边被占则顺时针试下一条边，四边全占再外扩螺旋
  （复用 `_find_item_spot` 骨架，[world.gd:3847-3856](../scripts/world.gd#L3847-L3856)）。
- 拾取：走近 + 现有拾取交互，命中检测对边缘物用竖片包围盒。

## 3. 客户端渲染

`chunk_manager.gd` 区块重铺循环里，`itemRef` 分发之后补一段边缘扫描：

```gdscript
for side in 4:
    var ref := TerrainMap.tile_edge(gt, side)
    if ref == 0: continue
    var def := ItemCatalog.get_def(TerrainMap.edge_item_id(gt, side))
    # renderRef "sticker:<name>" → STICKER_TEXTURES 预载表 → 小竖片 quad
```

- **几何**：单面 QuadMesh（不细分），世界高约 0.8~1.2m，贴纸原始宽高比；
  位置 = 边缘中点、底边离地 ~0.2m（世界高度取 tile height，与设计既定决定一致）；
  法线朝 tile 外侧（N/E/S/W 各 90°）。双面渲染（`cull_disabled`）——背面看是镜像，可接受。
- **材质**：unshaded + alpha scissor（与贴纸白描边硬边匹配，避免透明排序问题）；
  不上 paper 卷曲 shader——静态贴片，省顶点动画开销（平板性能优先，教训见
  tablet-perf 调优）。
- **合批**：同名贴纸多处出现用 MultiMesh 合批（与 `KAYKIT_SCATTER` 同款 `_batch` 路径），
  按 `sticker:<name>` 键控。
- 台阶侧面：若该边相邻 tile 更低（有 STEP_HEIGHT 落差），贴纸贴在台阶立面上
  （竖片正好覆在立面前 1~2cm），视觉上就是"挂在崖边"；平地则如小立牌立在边线上。
  两种情况同一份几何逻辑，只差 y。

**与 world-themes 的协调**：`prd/world-themes` worktree（未 merge）已把三张 preload 表
manifest 数据驱动化（PackRegistry）。`STICKER_TEXTURES` 表**跟随先合入者**：若 world-themes
先 merge，贴纸表直接进 manifest；否则先按编译期常量表落地、themes merge 时一并迁移。

## 4. 分期与验收

- **P1 服务端**：ItemDef.mount + 贴纸 builtin 定义（先用占位 renderRef）+ terrain_edit edge
  编辑与校验 + item_place/pickup edgeSide 分流 + `sticker_buy` 购买消息（扣花入包）；
  单测（edge 摆/拾/覆写/mount 错位拒绝/占用位图不受影响/余额不足拒买）。
- **P2 贴纸资产**：管线批量生成第一批 12 张（统一画风 prompt + 白描边 + trim + WebP），
  入 `res://assets/stickers/` + builtin 表填真 renderRef + 对拍校验。
- **P3 客户端**：TerrainMap.apply_patch 支持 edge + tile_edge 访问器 + chunk_manager 边缘
  渲染分支（含台阶立面）+ 摆放 UX + 物品页"贴纸小铺"购买栏；
  headless 冒烟（买→摆→patch→重铺可见→拾回）。
- **P4**：全套回测 + 真机观感（老板验收门）+ merge --no-ff。

验收标准（可机器验证）：headless 测试里对 (x,y,side) 发 item_place(edgeSide) →
收到 terrain_patch 含 `edge:[side,ref]` → TerrainMap.tile_edge 返回 ref → 重铺后场景树里
出现对应贴纸节点；item_pickup 后逆过程成立且 bag 计数 +1。

## 5. 拍板记录（2026-07-12）

1. **贴纸进背包 = 小红花商店购买**（§2.3）——给钱包经济新增消费出口。
2. **内置贴纸允许拾回**，"内置物一律拒拾"缩小为"mount:'tile' 的内置物拒拾"（§2.2）。
3. 第一批 12 张题材按 §1.2 候选清单执行，生成时可微调。
