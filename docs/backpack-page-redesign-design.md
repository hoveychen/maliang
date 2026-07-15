# 背包（物品页）重做设计

手机背面「物品」页从「6 列纵向滚动 + 礼盒图标 + 文字名 + ×N」重做成
「4×4 翻页 + 预渲染真图 + 数量角标 + 点击出左页详情/动作按钮」。

老板拍板要点（2026-07-15）：
1. 物品页做翻页（不是无限滚动）。
2. 去掉格子里的文字名。
3. 用物品的**预渲染真图**，不再是统一礼盒图标。
4. 点击物品 → 手机**左半页**弹出该物品详情，含**动作按钮**。
5. 数量学常规游戏：**图标右上角小角标**标数字，只有 1 个不显示（不写「×N」）。
6. 一屏约 **4×4**，上下滑动**翻页**、一次翻 4 行，带**磁力吸附回弹**。
7. **每个物品都要有点点念的名字**，点击即播（不止孩子自己起的名字）。

---

## 1. 现状（改造起点）

`scripts/phone_ui.gd`：
- `_build_items_page()`（958）建一个 `GridContainer.columns=6`（964）套在纵向 `ScrollContainer`（304）。
- `refresh_items()`（1026）全量重建：数据源 `_w.bag`（item_id→份数），def 从 `ItemCatalog.get_def` 取。
  - 贴纸（`renderRef` `sticker:`）显示本尊贴图；其余显示 `ic_gift` 礼盒图标。
  - 文字名：`名字` 或 `名字×N`（1082）。
  - 起名造物右上挂 `ic_note` 小喇叭，点播孩子录音（1065-1079 / `_play_name_voice`）。
  - 点格子：`composed:` → `_on_composed_item_tapped`；其余 → `_begin_placement`（直接进放置模式）。

服务端物品缩略图：`item_icons` 表（`persistence.ts:393` item_id→asset_hash），靠**离线工具
`tools/item_icon_capture.gd` 手动跑**按 renderRef 离屏渲染上传。`GET/POST /admin/item-icon/:id`
（server.ts:959）。**游戏客户端目前不消费这套缩略图**——只有 debug/admin 展示页用。

## 2. 预渲染真图：混合来源（老板选 C）

孩子刚造的造物是唯一 `randomUUID` id，服务端没缩略图——正是要换掉礼盒的对象。故：

⚠️ **实证修正（读码发现）**：现有 `GET/POST /admin/item-icon*` 全是 `debugAuthed` 门禁——
生产要 admin token，游戏客户端拿不到。所以「读服务端已烧图」和「客户端回填」两条对线上客户端
**都是断的**。修正如下：

- **读半边走新的公开只读端点**：新增 `GET /item-icons`（**无 token**，只回 item_id→hash 映射）
  给游戏消费。内置物（~154，离线工具早已回填生产）经此命中→ `api.fetch_texture(hash)`（`/assets/:hash`
  本就公开）拉图显示。
- **没命中就客户端现场离屏渲染**：把 `item_icon_capture.gd` 的渲染核心（斜俯视舞台 +
  按 renderRef 造节点 + 裁边）抽成运行时可复用的 **`ItemThumbnailer`**
  （`scripts/item_thumbnailer.gd`，`RefCounted`/自持 SubViewport）。缺图物品排队逐个渲染，
  出图 → 内存缓存（item_id→Texture2D，本会话）。孩子的新造物走这条。
- **不做客户端回填**：`POST /admin/item-icon` 仍 admin 门禁，且逐件渲染有 GPU 停滞风险——
  回填继续留给离线工具 `item_icon_capture.gd`（生产内置图已全）。
- **兜底**：渲染失败（renderRef 未注册等）仍回退礼盒 `ic_gift`。

渲染节流：复用 `item_icon_capture` 的经验——SubViewport 连续渲染多件后 GPU 累积会冻结，
运行时**一次只渲一件、逐帧节流**（背包一屏才 16 件，逐个懒渲染完全够）。缓存命中后不再渲。

## 3. 布局：4×4 翻页 + 磁力吸附（跨页右半=网格，左半=详情）

物品页占满 spread 跨页视口：
- **右半页 = 物品网格**：`GridContainer.columns=4`，一屏 4 行 = 16 格/页。
- **左半页 = 详情面板**：未选中时空态提示（「点一个玩意儿看看」+点点小像）；选中后显示大图 + 名字 + 动作按钮竖排。

### 3.1 纵向翻页 + 磁力回弹

不用 `ScrollContainer` 自由滚，改**分页容器**（照首屏横向翻页 `_phone_pager` 的 snap 逻辑，
方向换成纵向）：
- 各页竖排（每页高 = 视口可视高，含 4 行）。
- 拖拽纵向滚动，松手**吸附到最近页**（`create_tween` 缓动到页边界，`TRANS_BACK/EASE_OUT` 出磁力回弹感）。
- 页数 = `ceil(格数 / 16)`；>1 页显示纵向翻页圆点（复用 `_phone_dots` 概念，竖排）。
- 一次滑动跨一页（4 行），不是逐行。

## 4. 数量角标（去 ×N）

- 每格图标右上角叠一个圆形徽章 Label，显示份数数字。
- **份数 = 1 不显示徽章**（常规游戏惯例）。
- 位置右上角，与起名小喇叭角标错开（喇叭挪右下或详情面板里，避免两个右上角标打架）。

## 5. 点击 → 左页详情 + 动作按钮 + 点点念名

点格子不再直接进放置，而是：`_select_item(item_id)` → 左半页渲染详情 + **点点念该物品名**（见 §6）。

### 动作按钮（按物品类型条件显示，老板定的集合）

| 按钮 | 适用 | 实现 |
|---|---|---|
| **摆到地块**（地上/墙上） | 全部 | 普通物件走地面放置模式 `_begin_placement`；贴纸走墙面/边缘放置（edge tile）。一个按钮按物品 mount 分流。 |
| **装到身上** | 仅贴纸 | 复用 self-stickers 的 `send_player_attach`（Player.attachments）。**⚠️ 依赖 self-stickers 落 main**（见 §7）。 |
| **扔掉** | 全部 | 从背包扔到玩家身边一格（自动找空 tile 落地为可拾物品），可再捡回。复用 `item_place`+拾起，新增「就近落地」便捷路径。 |
| **拆开改改** | 仅积木造物（`composed:`） | 现有 `_on_composed_item_tapped`（B1 功能，老板没列但保留，不删既有能力）。 |

## 6. 点点念物品名（每个物品都有名字语音）

- **内置物品**（~154 个，名字固定：蓬蓬树·甲/岩石·乙/水井…）：走点点**预烧 WAV**，与
  fairy/onboarding/intro 预制台词同一管线（`server/tools/gen_voice_lines.mjs`，音色
  YunxiaNeural）。资产随包，运行时按 item_id/name 查预烧音频播放。
- **造物**（动态名，小明的城堡…）：无法预烧 → 点点**运行时 TTS**（现有 fairy voice / edge_tts 通道，
  念 def.name）。
- **孩子录了名字的造物**（`nameVoiceAsset`）：优先播**孩子自己那句录音**（更亲切），没有才点点念。
- 触发：点击物品（详情打开）即播；详情面板也放一个「再听一次」按钮。

## 7. 依赖与冲突

- **self-stickers（在飞 worktree，P4 未 merge）**：`player_attach` handler + 装扮 app 在那边。
  「装到身上」动作按钮**依赖它先落 main**。若本 plan 到 P4 时 self-stickers 未 merge，
  「装到身上」按钮先**灰置/隐藏**并在 TASKS 标注，待 self-stickers 落地再接线（不另造 attach 路径）。
- phone_ui.gd 是大文件，多处改动集中在 `_build_items_page` / `refresh_items` 及新增详情/翻页/缩略图方法。

## 8. 验收（可观察）

- headless：物品页构建不崩、4 列网格、翻页页数计算正确、数量角标逻辑（=1 不显）、缩略图缺图回退礼盒。
- 带窗截图：塞满背包 → 物品页显示真图（非礼盒）、4×4、纵向翻页吸附、点击出左页详情+按钮。
- 服务端单测：扔掉 handler（就近落地/可拾回）、item-icon 回填。
- 真机手感（老板域）：翻页磁力回弹力度、点点念名。
