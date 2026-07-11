# 角色锚点设计：AIGC 立绘的头顶/手部定位与贴纸附着（character-anchors）

> 状态：定稿（2026-07-12，开放问题老板已拍板，见 §7）。锚点检测方案已经 PoC 实证（见 §2）。
> 目标一句话：给每个 AIGC 生成的角色立绘求出**头顶**（戴帽位）与**双手**（持物位）的归一化锚点，
> 存进 appearance 元数据，客户端据此把贴纸/道具挂到角色身上的固定位置。
> 贴纸物品目录与 [sticker-items-design.md](sticker-items-design.md) 共用——同一张贴纸既能挂 tile 边也能贴角色。

## 0. 现状（已核实）

- 角色是**单面片 QuadMesh + 整张立绘贴图**，无骨骼无部件；锚点在脚底
  （offset 上移半高，[paper_character.gd setup()](../scripts/paper_character.gd)）。
  所以"固定位置"只能是**立绘图片上的归一化坐标**，运行期换算成面片 local offset。
- 立绘生成链：生图 → 抠图 → 朝向检测（vision LLM，`OpenRouterOrientationAdapter`）→
  必要时 `flipHorizontal` → `trimToContent` 裁贴身盒 → `putAsset`
  （[orchestrator.ts:52-90,139-140](../server/src/orchestrator.ts#L89-L90)）。
- appearance 下发链路现成：`scene_entered.characters[].appearance` / `character_spawned` /
  bootstrap `world.characters`；客户端 `_spawn_server_character` 消费
  （[world.gd:3543-3603](../scripts/world.gd#L3543)）。
- 现有"角色头顶挂东西"先例（情绪气泡/notice 气泡/仙子音符）全是**世界空间独立节点 +
  每帧 follow 头顶**，不是 PaperCharacter 子节点——它们只需要"在头上方悬浮"，
  不需要贴合身体，与本设计的诉求不同（见 §4 取舍）。

## 1. 锚点数据模型

```ts
// Character.appearance 扩展：
appearance: {
  visualDescription: string;
  spriteAsset: string;
  scale: number;
  anchors?: {                      // 归一化到 trim 后立绘图片，x,y ∈ [0,1]，原点左上
    headTop: { x: number; y: number };   // 头顶正位（两耳之间，帽子该戴的地方）
    handL:   { x: number; y: number };   // 画面左侧的手/爪/翅尖
    handR:   { x: number; y: number };   // 画面右侧
    source: 'vision' | 'fallback';       // 检测来源（fallback=固定比例兜底，见 §3）
  };
}
```

- **坐标系约定：归一化到最终入库的立绘**（即 flip、trim 之后）——检测必须发生在
  `flipHorizontal`/`trimToContent` **之后**、`putAsset` 前后皆可，保证坐标与客户端
  拿到的贴图逐像素对应。
- `anchors` 可缺省：老角色未回填、检测失败未兜底成功时为空，客户端按 §3 兜底比例现算。

## 2. 锚点检测管线（PoC 已实证，2026-07-12）

### 2.1 PoC 结论

拿 prod default 世界全部 12 个角色立绘（人形/兔/猫/狐/鹿/鸟/熊/龙/猫头鹰/松鼠，覆盖两足/
四足/带翅膀）跑 `google/gemini-3.5-flash` 指点检测（512px 缩图，要求返回 0-1000 归一化
JSON 点位），同时跑 alpha 启发式对照：

1. **双手 12/12 可用**：人形点在手、四足点在前蹄、鸟类点在翅膀、松鼠捧橡果两手点在橡果上——
   非人形没有崩。
2. **头顶也该用 LLM，不用 alpha**：带长耳/尖耳角色（兔/狐/猫头鹰）alpha 最高点落在**耳尖**，
   LLM 的 head_top 落在**两耳之间的头顶正位**——帽子该戴的地方。这反转了"头顶用 alpha
   就够"的预判。alpha 降级为兜底 + 合法性校验。
3. 已戴帽角色（睡帽猫/毛线帽熊）LLM 点在帽顶，语义合理（帽上叠帽视觉成立）。
4. 成本：每角色一次调用，flash 档几乎可忽略。
5. ⚠️ 样本多为预制村民（画风统一）；孩子语音自造角色可能更奇形怪状，兜底路径（§3）必须常备。
   ⚠️ 本地 PoC 经 ssh 中转（港区 403）；prod 上同一套 OpenRouter vision 基建（朝向检测）
   一直正常跑，据此**推断**生产无网络问题——落地 P1 要在 prod 实测一次。

PoC 脚本与 12 张标注对比图存档：session scratchpad `poc_anchors.py` / `grid.png`
（定稿后随 P1 一并归档 wiki）。

### 2.2 生产管线

- 新增 `AnchorDetectAdapter`（接口 + OpenRouter 实现 + mock 确定性实现，
  与 orientation 适配器同构、共用 `OpenRouterClient` 的看图提问方法与 `visionModel` 配置）。
- Prompt 要点（PoC 原文微调）：说明是儿童游戏全身立绘、可能人形/动物/幻想生物；
  要 `head_top`（帽子该戴的头顶正位）、`left_hand`/`right_hand`（画面左右侧的手/爪/翅尖，
  无四肢则取中腰身体边缘）；只回 JSON 数组 `{label,x,y}`，0-1000 归一化。
- **合法性校验**（防 LLM 点飞）：每个点半径 3% 图宽内必须存在 alpha≥16 的像素；
  head_top 的 y 必须在图片上半部；违规单点降级为该点的兜底值（§3），整体 `source` 记 `vision`
  仅当三点全部原生通过。
- 时机：`createCharacterAsync` 立绘入库后同步追加一步；失败不阻塞角色创建
  （anchors 缺省即可，客户端有兜底）。玩家形象生成走同一函数，锚点随立绘一起算好后
  存入设备档案 `user://profile.json`（服务端返回体带 anchors，客户端存档）。

### 2.3 存量回填

管理端点 `POST /admin/detect-anchors`（admin token 门禁，先例 `/admin/retrim-sprites`）：
遍历所有 characters 行（含各世界），对有 spriteAsset 且无 anchors 的批量检测、原地写回。
玩家形象在设备档案、服务端够不着（player-sprite 已知约束）——老角色玩家首次进世界时
客户端发现 profile 无 anchors，可请求服务端按 spriteAsset 现算一次（`anchor_request` 消息，
量小、有 LRU 意义不大，直接算）。

## 3. 兜底比例（无 anchors 时客户端现算）

- headTop：alpha 最顶部不透明行中心（客户端有像素访问能力，Image.get_pixel）；
  算不了（贴图未就绪）就 (0.5, 0.02)。
- handL/handR：y=0.55 行上 alpha 的最左/最右不透明像素，向内收 5% 图宽。
- 这套就是 PoC 里的 alpha 启发式——对长耳角色帽子会戴到耳尖上，不完美但不穿帮。

## 4. 客户端附着渲染

**取舍：贴纸做 PaperCharacter 的子节点**（区别于气泡的世界空间 follow）——帽子/手持物
必须跟角色面片一起倾斜（rotation.x 随相机）、一起翻面演出，世界空间 follow 做不到贴合。

```gdscript
# PaperCharacter 新增：
func attach_sticker(slot: String, tex: Texture2D) -> void   # slot: head_top / hand_l / hand_r
func detach_sticker(slot: String) -> void
```

- 子节点为小 QuadMesh（贴纸原始宽高比，世界宽 ≈ 角色高的 0.22，帽/手可分别调）；
  local 位置由归一化锚点换算：
  `x = (ax - 0.5) * tex_w * pixel_size`、`y = (1 - ay) * tex_h * pixel_size`（锚点在脚底、y 向上），
  z 前移 1~2cm 防 z-fight。头顶槽贴纸**底边**对齐锚点（帽子坐在头上），手槽**中心**对齐。
- 材质 unshaded + alpha scissor（同 tile 贴纸）；**不复制 paper 卷曲 shader**——
  子面片小、卷曲不同步肉眼难辨，先省一份 shader 参数同步（平板性能优先）。
  真机验收若见"帽子悬浮感"再补同参卷曲。
- **已知瑕疵（v1 接受）**：idle 动画帧身体微动而锚点按静态立绘算，帽子有毫米级不贴——
  idle 图集是 unionCrop 对齐的、幅度小。翻面演出时子节点随父 basis 镜像，
  锚点 x 无需特殊处理（子节点跟着面片翻）；**此条待 P3 headless 实测确认**，
  若翻面走的是 shader UV 翻转而非节点变换，则锚点 x 需要镜像，落地时以实测为准。

## 5. 附着状态与协议

```ts
// Character 新增（NPC；玩家的存设备档案 + actors 流转发）：
attachments?: Array<{ slot: 'headTop'|'handL'|'handR'; itemId: string }>;  // itemId=贴纸实体 id
```

- WS 新消息 `character_attach { worldId, characterId, slot, itemId|null }`（null=摘下）：
  服务端校验贴纸在发起玩家背包（贴上=扣背包，摘下=回背包，复用 bagTake/bagAdd + bag_update）、
  校验 itemId 是 `mount:'edge'` 之外还得允许"可贴角色"——**贴纸实体天然两用，不加新字段**，
  非贴纸物品拒绝。落库 characters 行，经 WorldHub 场景定向广播 `character_attach` 给同场景。
- 客户端收到 → 查场景角色副本（按 id 现查，勿持引用——player-interaction 教训）→
  `attach_sticker/detach_sticker`。
- 交互入口：对话/点选角色时出贴纸盘（复用表情盘 UI 骨架），选贴纸 + 选槽位。
  **v1 三个槽全开**（headTop/handL/handR，老板拍板 2026-07-12）：贴纸盘选中贴纸后
  出槽位选择（头顶/左手/右手三个点位图标）。

## 6. 分期与验收

- **P1 服务端检测**：AnchorDetectAdapter（mock+openrouter）+ 合法性校验 + createCharacterAsync
  接入 + `/admin/detect-anchors` 回填端点；单测（mock 确定性、校验降级、坐标系 flip/trim 对齐）；
  prod 实测一次真调用（消 §2.1 的网络推断）。
- **P2 存量回填 + 下发**：prod 跑回填、抽查画点复核；appearance.anchors 全链路下发
  （scene_entered/character_spawned/bootstrap/玩家档案）。
- **P3 客户端附着**：PaperCharacter.attach_sticker + 兜底比例现算 + 翻面/倾斜实测；
  headless 冒烟（造角色→anchors 下发→attach→截帧可见帽子在头顶）。
- **P4 状态与交互**：character_attach 协议 + 背包扣还 + 贴纸盘 UI（头顶/左手/右手三槽）；
  server 单测 + headless 全绿。
- **P5**：真机手感（老板验收门）+ merge --no-ff。

验收标准：headless 场景里对指定角色发 `character_attach(headTop, sticker_sun)` →
广播回执 → 截帧在角色头顶锚点位置检出贴纸像素；摘下后消失且背包计数复原；
无 anchors 的角色走兜底比例不崩。

## 7. 拍板记录（2026-07-12）

1. **依赖顺序**：sticker-items 先行（贴纸目录是共用地基），本篇 P1/P2（纯服务端检测+回填）
   可与之并行；P3 起依赖 sticker-items 的贴纸资产。
2. 收费只发生在**购买**贴纸时（小红花商店，见 sticker-items §2.3）；贴上/摘下不另收费，
   摘下回背包可复用。
3. **v1 三槽全开**（headTop/handL/handR），贴纸盘带槽位选择（§5）。
