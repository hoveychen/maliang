# 造物体型档：prop 也有「小/中/大」

## 背景（现状事实）

- **造物（SDF prop）视觉尺寸是绝对米**：`SdfPropSpec.parts` 各部件 r/len/size/hip_h 由 LLM 直接按米定（约定小物 0.1~1.5m、建筑 1~3m），客户端 `sdf_prop.gd` 用 `rest_aabb(prims)` 按部件米数直接建、**不归一化**。`SdfPropSpec` 目前**无整体 scale 字段**。
- **造物引导已收 `size`**（`prop_creation_options.ts`：kind/color/size/motion，size 选项与造角色共享同 id 的 小/中/大 剪影），但这个 size 目前只喂生图/剪影语义，不改造物实际大小。
- **tile 占格**：造物落地成 item 实体，占 `footprintW×footprintH` 格（每类自带 span，奇数边锚点居中）；这是逻辑挡路格，与视觉米数解耦。

对照角色（character-size）：角色被强制归一到 `6.0×体型`；造物没有归一，是「LLM 绝对米 × 体型档倍率」。两套量纲独立，但**体型档倍率复用同一张表** `sizeToScale`（小0.7/中1.0/大1.4）。

## 目标

让造物时选的「小/中/大」真正整体放缩造物，并（可选）联动占格。

## 决策点（待老板拍板）

### 1. 缩放实现：几何相乘 vs 节点变换
- **(A) 几何相乘（推荐）**：`SdfPropSpec` 加 `scale:number`（默认 1.0，由 size 经 `sizeToScale` 定）；客户端 `sdf_prop.gd` 构建 prims 时把每个部件的 pos/r/len/size/hip_h/hover_h 等**统一乘 scale**。raymarching 在缩放后的几何上跑，阴影 AABB、blob 半径自动跟随，无额外坑。
- **(B) 节点变换缩放**：给 SDF 根节点设 `scale` transform。对 raymarch shader 不透明（shader 在固定局部空间求值），易踩坐标系坑，不推荐。

### 2. footprint 是否随体型档变
- **(A) 联动（推荐轻量版）**：big 造物 span +1 环（或 `ceil(baseSpan×scale)`），大物件占更多格、挡路更真实；small 保持不变（避免 0 格）。
- **(B) 固定**：占格恒等原 span，只变视觉。改动最小，但大造物视觉大、脚下占格没变，可能出现「大物件被踩进去/穿过」。

### 3. 驱动源（与 character-size 同构）
- 引导式：`guideProp` 已有 `state.attrs.size` → 汇总描述含体型词 → `designSdfProp` 判定。
- 自由文本：LLM 从描述判体型。
- 统一经 `sizeToScale` 落到 `SdfPropSpec.scale`；mock 走 `inferSizeFromText` 确定性。

## 贴纸随体型（老板提的关注点）——已基本解决

贴纸附着走 `PaperCharacter.attach_sticker`，尺寸由 `visible_height()` 定，而 `visible_height() = cellH × pixel_size` 已含角色 `body_scale`（character-size 那轮）。所以角色变大 → visible_height 变大 → 贴纸按比例跟着变大，**尺寸映射已自动正确**。本 plan 只需**真机确认**大/小体型角色戴帽/挂饰比例观感，无需再改附着逻辑。

## P 任务草案（拍板后细化）

- **P1** 服务端：`SdfPropSpec.scale` + designSdfProp/guideProp 落 scale（sizeToScale）+ 单测。
- **P2** 客户端：`sdf_prop.gd` 构建 prims 时整体乘 scale（方案 A）+ headless 冒烟。
- **P3**（若选 footprint 联动）：items 占格随体型档 + 语义校验 + 单测。
- **P4** 全套回测 + merge --no-ff（验收门）。真机手感调参留老板。
