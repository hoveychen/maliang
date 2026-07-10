# 多场景 + 地形上服务端 设计（草案 v1，待老板拍板）

> 状态：设计草案，**未动生产代码**。目标是让世界从「一张写死在客户端的地图」变成「服务端下发的、可以有多张的场景」，为 MMO 铺路。
>
> 触发点：老板要做多场景，且判断「地图不存服务端就没法让多个玩家进同一个世界」。
> 本文第 0 节先纠正这个前提——地图现在**已经**是所有客户端一致的——然后说明真正该解决的是什么。

---

## 0. 现状（已读代码核实）

| 事项 | 现状 | 出处 |
|---|---|---|
| 地形数据 | **纯静态、确定性生成、无随机状态**。没有 seed，没有 `randf()`，没有噪声 | `scripts/terrain_map.gd:3` 文件头注释 |
| 地形形状 | 手绘式硬编码：主峰 (37.5, 6.5)、池塘 (24.5, 24.5)、风车丘 (59.5, 54.5) | `terrain_map.gd:_paint()` |
| 地形存储 | 三个 static `PackedByteArray`：`_types` / `_heights` / `_depths`，各 75×75 = 5625 B | `terrain_map.gd:27-29` |
| 地形访问 | 全部经 static 访问器：`tile_type` / `tile_height` / `tile_depth` / `can_step` / `tile_center` | `terrain_map.gd:32-71` |
| 地形构建时机 | 首次访问时 `_ensure_built()` 惰性 `_paint()` | `terrain_map.gd:76` |
| POI | 客户端常量数组（tile / radius / trigger / name / aliases），4 个 | `scripts/world.gd:270` POIS |
| POI 权威方向 | **客户端 → 服务端**：`world_info` 上报地名，服务端**只存内存、不落盘** | `backend.gd:send_world_info`、`persistence.ts` `#locations` |
| POI 用途 | 喂意图 LLM，把「去池塘」归一到真实地名 | `tasks.ts:pickTaskCandidate` 读 `getLocations` |
| 世界数量 | 固定一个 `default`，客户端启动即 `get_world("default")` | `world.gd:_bootstrap`、`server.ts:180` |
| 角色/物件归属 | 都按 `worldId` 键控 | `characters.world_id`、`props.world_id` |
| 钱包/委托归属 | 按 `(worldId, playerId)`（2026-07-10 刚改） | `wallets`、`player_tasks` 表 |
| 玩家位置归属 | **只按 `playerId`，不带 worldId** | `persistence.ts:setPlayerTile` |
| 角色位置 | `Character.position`（tile），角色本身带 worldId | `positions_report` |

### 0.1 结论：多玩家早就看到同一张地图

因为地形是**代码而非数据**——一个纯函数，输入为空，输出恒定。两台平板逐 tile 一致，不是因为同步，而是因为它们跑同一份 `_paint()`。

所以「存地形到服务端」并不能解决「多玩家看同一张图」——那个问题不存在。真正存在的问题是下面三个：

1. **没有版本协商。** 两台平板装了不同版本的 APK，`_paint()` 一改就各看各的，服务端无从察觉。
2. **POI 的权威方向是反的。** 服务端靠客户端上报才知道有哪些地名，而且不落盘。客户端版本不一致时，意图 LLM 的地名表跟着漂。
3. **地形不可编辑、不可增加。** 想要第二张地图，只能再写一个 `_paint2()` 并发版客户端。这才是「多场景」真正卡住的地方。

---

## 1. 需要老板拍板的头号决策：`world` 和 `scene` 是什么关系？

这不是措辞问题——它决定了**钱包属于谁**，而钱包我们刚刚改完。

### 模型 A：world 就是 scene（一个世界 = 一张地图）

村庄是一个 world，森林是另一个 world，玩家在 world 之间传送。

- ✅ 改动最小：`characters` / `props` 已经按 `worldId` 键控，天然就分场景了。
- ❌ **钱包会跟着场景走**。`wallets` 的主键是 `(world_id, player_id)`——小朋友从村庄走到森林，钱包就变成另一份，花归零。这显然不是我们要的。
- ❌ 记忆也一样：村庄的小蓝和森林的小绿分属不同 world，本来就该如此；但「玩家档案」「小红花」这类跨场景的东西无处安放。
- ❌ 要修的话，得把钱包主键从 `(world_id, player_id)` 退回 `player_id`——**推翻刚做完的那个 PR**。

### 模型 B：world 是「世界」，scene 是世界里的一片区域（推荐）

`default` 世界里有 `village` / `forest` / `beach` 三个场景。玩家始终在同一个 world 内，在 scene 之间走动。

- ✅ **钱包/委托的 `(worldId, playerId)` 主键原样保留**，一朵花走到哪都还是那朵花。经济是世界级的，符合直觉。
- ✅ MMO 语义干净：一个 world = 一个服务器/一个班级，里面很多小朋友分布在不同场景。
- ✅ 记忆按 `(NPC, 玩家)`，NPC 属于某个 scene，天然成立。
- ❌ 要给 `characters` / `props` 加 `scene_id` 列并迁移存量（当前全部隐含属于 `village`）。
- ❌ 玩家位置要从 `players.position` 挪到 `(world_id, player_id, scene_id)`。

**推荐模型 B。** 理由：它把「经济/身份/记忆」和「空间」这两层正交开了，而模型 A 把它们绑死在一起，代价是刚落地的钱包改造要返工。

> 下文所有设计按模型 B 展开。若老板选 A，第 3、4 节的表结构需要重画。

---

## 2. 顺带暴露的一个真缺陷

`setPlayerTile(playerId, tile)` 只按 `playerId` 存位置，**不带世界/场景**。

单场景时它是对的。一旦有了第二个场景，「小明在 (12, 30)」就是个没有意义的坐标——(12,30) 是村庄的池塘边，还是森林的空地？重进世界时会把小明放到错误场景的对应格子上。

这是 2026-07-10 那个 `char-position-sync` PR 留下的、当时看不出来的坑。多场景第一步就得修：位置的键必须是 `(world_id, scene_id, player_id)`。

---

## 3. 服务端数据模型（模型 B）

新增一张表，改两张表：

```sql
-- 新增：场景 = 一张地图
CREATE TABLE scenes (
  world_id      TEXT NOT NULL,
  scene_id      TEXT NOT NULL,          -- 'village' / 'forest' / ...
  name          TEXT NOT NULL,          -- 展示名「村庄」
  terrain_asset TEXT NOT NULL,          -- 地形二进制的内容寻址 hash（复用现有 assets 库）
  terrain_version TEXT NOT NULL,        -- = terrain_asset，客户端据此判缓存/版本
  grid_tiles    INTEGER NOT NULL,       -- 75，随场景走，不再是全局常量
  pois          TEXT NOT NULL,          -- JSON: [{tile,radius,trigger,name,aliases}]
  portals       TEXT NOT NULL,          -- JSON: [{tile,radius,toScene,toTile}]
  PRIMARY KEY (world_id, scene_id)
);

-- 改：角色/物件归属到场景
ALTER TABLE characters ADD COLUMN scene_id TEXT NOT NULL DEFAULT 'village';
ALTER TABLE props      ADD COLUMN scene_id TEXT NOT NULL DEFAULT 'village';

-- 改：玩家位置带上场景（现在只有 players.data.position，是全局的——见第 2 节）
CREATE TABLE player_positions (
  world_id  TEXT NOT NULL,
  scene_id  TEXT NOT NULL,
  player_id TEXT NOT NULL,
  tile_x    INTEGER NOT NULL,
  tile_y    INTEGER NOT NULL,
  PRIMARY KEY (world_id, scene_id, player_id)
);
-- 另需记「玩家当前在哪个场景」：players.data.currentScene
```

**不动的**：`wallets` / `player_tasks` / `memories` / `chat_turns` / `visits` 全部保持 `(world, player)` 或 `(npc, player)` 维度。这正是选模型 B 的收益。

### 3.1 地形的下发格式

现在的内存布局就是三个等长字节数组，直接序列化即可：

```
magic   "MLTR"           4 B
version u8               1 B
gridW   u8               1 B   (75)
gridH   u8               1 B   (75)
tileSize f32             4 B   (2.0)
types   u8[W*H]       5625 B
heights u8[W*H]       5625 B
depths  u8[W*H]       5625 B
                    ─────────
                     16,886 B
```

约 16.5 KB。**已实测**（Godot headless dump 三数组后 `compress(COMPRESSION_GZIP)`）：

```
tiles=5625  raw=16875 B  gzip=495 B  ratio=34.1x
```

**495 字节**——比一张立绘的缩略图还小，下发成本可以忽略。

存进现有的 `assets/<hash>` 内容寻址资产库，客户端复用 `api.gd` 已有的磁盘缓存——hash 不变就不重新下载。地形改了 → hash 变 → 客户端自动重取。**版本协商问题因此自动消失**：客户端拿到的地形就是服务端那份，不存在两台平板算出不同地图。

> 注意 `#loadAssets` 启动时把所有资产读进内存 Map（见资产盘点）。地形 16 KB 一张，可忽略。

### 3.2 POI 权威方向扭转

POI 从 `world.gd:270` 的常量搬到 `scenes.pois`，随场景下发。

- 客户端不再 `send_world_info(locations)` 上报地名（消息保留以兼容旧客户端，服务端忽略其 locations）。
- `store.getLocations()` 从读内存 Map 改为读 `scenes.pois`，**顺带获得持久化**。
- `trigger` 字段（`poi_pond` 等）仍由客户端映射到仙子台词，服务端不管台词。

---

## 4. 客户端改造（比想象中小）

关键发现：**`TerrainMap` 的全部消费方都只经过 static 访问器**（`tile_type` / `tile_height` / `can_step` / …），没有一处直接摸 `_types` 数组。`chunk_manager` / `pathfinder` / `occupancy_map` / `world.gd` 全部如此。

所以只需换掉「三个数组从哪来」，访问器签名一律不动：

```gdscript
# terrain_map.gd
static var _loaded := false

## 从服务端下发的二进制载入（替代 _paint()）。
static func load_from_bytes(buf: PackedByteArray) -> bool: ...

static func _ensure_built() -> void:
    if _loaded: return          # 服务端地形已就位，别用 _paint() 盖掉
    _paint()                    # 离线/回测回退：仍然确定性生成
    _loaded = true
```

- **离线模式与 headless 回测不回归**：拉不到地形就回退 `_paint()`，与今天完全一致。
- `GRID_TILES` 想变成随场景来的运行期值会很痛。它被 18 处引用，其中两处是**编译期常量推导**，运行期值根本喂不进去：

  ```gdscript
  chunk_manager.gd:13   const CHUNKS_PER_SIDE := WorldGrid.GRID_TILES / CHUNK_TILES   # 3
  occupancy_map.gd:10   const CELLS := WorldGrid.GRID_TILES * 2                       # 150
  ```

  **建议第一版所有场景一律 75×75**，`grid_tiles` 字段照存但服务端校验必须等于 75。等真需要不同尺寸的地图时，再把这两个 `const` 改成运行期初始化——那是独立的一个 PR。

### 4.1 场景切换

- `GET /worlds/:id` 返回体加 `scenes: [{sceneId, name, terrainAsset, ...}]` 与玩家的 `currentScene`。
- 客户端进世界 → 取 `currentScene` → 拉该场景地形 + 角色 + 物件。
- 走到 portal → 发 `enter_scene {worldId, sceneId}` → 服务端换 `currentScene`、回该场景的角色/物件/地形 hash → 客户端卸载旧场景、载入新场景。
- `positions_report` 加 `sceneId`。

---

## 5. 谁来生成第一份地形数据？

`_paint()` 已经画好了村庄。第一版不要手搓地图编辑器——写一个 Godot headless 导出脚本：

```
godot --headless --script res://tools/export_terrain.gd -- --out village.mltr
```

把 `_paint()` 的结果 dump 成 §3.1 的二进制，`POST /admin/scenes` 入库。**导出的字节与客户端 `_paint()` 的输出逐字节相同**，因此上线当天玩家看到的地图与今天完全一致——零视觉变化，纯粹把数据源从客户端挪到了服务端。这是一个可验证的验收标准：`sha256(导出文件) == sha256(客户端内存三数组拼接)`。

第二张地图（森林）再谈怎么产出：手绘 tile 编辑器、程序化生成器、或者让 LLM 出 tile 布局。这一步之前不必决定。

---

## 6. 建议的实施顺序

每一步独立可上线、可回退：

1. **地形导出 + 下发，但客户端仍回退本地生成**（feature flag）。验收：导出字节 == 本地生成字节。
2. **客户端改读服务端地形**，本地生成降级为离线回退。验收：真机地图无视觉变化。
3. **POI 搬到服务端并下发**，`world_info` 的 locations 变成 no-op。验收：意图 LLM 的「去池塘」仍能归一。
4. **修玩家位置的场景键**（第 2 节的缺陷）+ `scene_id` 加列迁移。存量全部落到 `village`。
5. **portal + `enter_scene` 协议 + 第二张地图**。此时才真正「多场景」。

前四步做完，世界看起来跟今天一模一样，但地图已经在服务端了。第五步才是新玩法。

---

## 7. 待确认 / 未验证

- [ ] **模型 A 还是 B**（第 1 节）——这个不定，下面全是空谈。
- [ ] 多场景下 NPC 能否跨场景走动（`deliver_message` / `chat_with` 的目标在别的场景怎么办）。
- [ ] 玩家 presence（看到别的小朋友）不在本设计范围内，属于 MMO 的下一层。

已核实、不必再查的：

- ✅ 没有任何代码直接访问 `_types` / `_heights` / `_depths`（grep 全仓，只有 `terrain_map.gd` 自己碰）——所以换数据源不动消费方。
- ✅ 地形 gzip 后 495 B（实测，非估算）。
- ✅ `GRID_TILES` 有两处编译期 `const` 推导，第一版应锁死 75。
