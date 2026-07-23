# 壁挂物品设计（home-wall-decor）

室内房间（RoomStage）三面墙上「挂东西」：挂画 / 窗 / 贴纸。给孩子的小屋加一层墙面装饰，
让空墙也能被布置——延续「充实室内」的方向（前序：Room Stage `docs/home-interior-room-stage`、
起始家具充实地面）。

## 核心决策：复用 edge/sticker 系统，不新造

游戏早有一套完整的「tile 边缘挂载」系统（`docs/sticker-items-design.md §3`），壁挂物就是它在
室内墙面上的一个特例，无需任何新的数据模型或渲染管线：

| 层 | 位置 | 作用 |
|---|---|---|
| item def | `server/src/items.ts` `sticker()` helper，`mount:"edge"`，renderRef `sticker:<name>` | 现有儿童贴纸（sun/flower/star/heart…） |
| 数据 | `TerrainMap._edges`（每 tile 4 层 N/E/S/W），`edge_item_id(tile, side)` | 一张挂画 = 某 tile 某边挂了一个 edge 物 |
| 渲染 | `chunk_manager.gd` 贴纸 batch（竖片 MultiMesh + `sticker_edge.gdshader`） | edge 物渲染成贴墙竖片 |
| 放置 | `world.gd` `_place_is_edge` / `_confirm_placement`（`send_item_place` 带 edge） | 幽灵预览 + 落地 |

**关键洞察：RoomStage 三面墙 = 房间格的周界 tile 边。** 房间格区间 `[19..28]²`
（`world.gd` `ROOM_ORIGIN_TILE=(19,19)` / `ROOM_N=10`），墙对应：

- **后墙** = `y==19` 行 tile 的 **N 边**（`EDGE_N`）
- **左墙** = `x==19` 列 tile 的 **W 边**（`EDGE_W`）
- **右墙** = `x==28` 列 tile 的 **E 边**（`EDGE_E`）
- **前墙**（`y==28` 的 S 边）**不建**（相机从前开口俯看进屋），故不参与

而 RoomStage 的三面墙**内壁面恰好落在这些周界 tile 边上**：房间世界坐标跨 `[38,58]`（中心 48），
后墙内壁在世界 z=38，正是 `y=19` tile 的 N 边（世界 z=38）。所以一张挂在周界墙边的 edge 贴纸，
其 XZ 位置本就贴在墙面上——室内 edge 贴纸原本就会渲染（室内重做 `set_terrain_hidden` 只隐地面/水面
mesh，保留 deco 层且 `update` 不跳过），**只是渲在地面高度、朝外**。壁挂要做的只有两件事：抬到墙高、
面朝屋内。

## P1 — 墙面渲染

`chunk_manager.gd` 新增纯函数 `edge_sticker_pose(side, gt, indoor, origin, n)`，返回贴纸相对 tile
中心的位姿 `{off: Vector3, yaw}`：

- **室内房间周界墙边**（`is_room_wall_edge` 判定为真）：
  - Y 抬到墙高中段 `WALL_STICKER_CENTER = RoomStage.WALL_H * 0.5`（竖片底边 = 中段 − STICKER_H/2）
  - yaw 翻 180°（原朝外→面朝屋内 = 朝向 tile 中心 = 朝房间内）
  - 沿边法线向**屋内**内移 `STICKER_OUT`（防与墙面 z-fight）
- **其余**（室外，或室内非墙边）：保持原行为——贴地（`STICKER_LIFT`）、朝外、外移。

`_skin` 的边缘贴纸循环改调该纯函数。房间周界由 `world.gd` 进室内时 `set_room_bounds(ROOM_ORIGIN_TILE,
ROOM_N)` 告知（出室内传 n=0 → 判定恒假 → 一律走室外贴地路径）。

判定与位姿都是**纯函数**，`test_wall_decor.gd` 直接单测三面墙判定 + 抬高/朝向/内移，不依赖
MultiMesh transform 回读（headless dummy 后端读不回）。

## P2 — 室内墙面放置

`world.gd` 室内 edge 放置吸到最近的房间墙：新增 `_snap_to_room_wall(want)`，取到后/左/右三墙的最近者
（并列偏好后墙），返回该墙的周界 tile + side。两处调用：

- `_begin_placement`（默认落点）：从玩家所站 tile 吸到最近墙。
- 点地挪位（`_unhandled_input` 放置分支）：把点到的 tile 吸到最近墙。

放置幽灵在室内墙边改成**竖直面板**（沿墙宽 · 竖 `STICKER_H` · 薄）、抬到墙高中段
（`_place_wall_lift`，与 P1 渲染位姿对齐）；tile 物品与室外贴纸保持原贴地薄条。占用的墙边不在吸附里
避让——合法性检查（`edge_item_id` 非空即红）会红标，孩子沿墙另点即可（零挫败）。

## P3 — 美术档

**MVP：复用现有儿童贴纸挂墙**——sun / flower / star / heart 等，够可爱、儿童房合适，`mount:"edge"`
已就位，零新资产。game-pilot 眼验：爱心贴纸挂上后墙、朝屋内、位于墙面中段，观感成立。

**后续（老板要真「挂画 / 窗」再做）**：加 framed picture / window 的 item def（同 `mount:"edge"`，
renderRef `sticker:<name>`），需新资产——走 fable subagent 雕 SDF 或生图端点
（见 `sdf-props-use-fable-subagent` / `image-model-eval-and-ip-policy` 记忆）。机制无需再改，只加资产 + def。

## 已知取舍 / 边界

- **world-bend 曲率**：`sticker_edge.gdshader` 跟随小星球曲率下压（`VERTEX.y -= curvature *
  dot(VERTEX.xz)`），而 RoomStage 墙是平的 BoxMesh。室内以房间中心为渲染原点，墙面最远 ~10m，
  下压 ≤ ~0.3m（`curvature=0.0015`）。实测后墙中段爱心观感正常、清晰贴墙；若日后要像素级贴合，
  可对室内贴纸材质关曲率（代价：贴纸 batch 按室内/室外分键）。当前 MVP 接受此微差。
- **只挂周界墙**：室内非周界 tile 边的 edge 贴纸仍贴地（不会浮在半空当墙挂）——放置已吸到墙，
  正常玩法不会产生室内非墙边贴纸；seed 到内部边则退化为贴地，无害。
- **网格**：房间仍占 50×50 世界网格里的 `[19..28]²` 10×10；`GRID_TILES` 运行时化后房间尺寸由
  `ROOM_N` 定，改房间大小 `_snap_to_room_wall` / `is_room_wall_edge` 自动跟随（都读 origin/n）。
