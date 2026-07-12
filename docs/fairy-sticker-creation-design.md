# 小仙子造贴纸设计（fairy-stickers）

小仙子的第三种引导式创造 goal：`sticker`。与 `character`（造角色）、`prop`（造物）平行，
产出一张**扁平 die-cut 贴纸**（不是 SDF 3D 立体），作为 `mount:'edge'` 的 ItemDef 进背包。
贴到 tile 边缘（放置模式）/ 贴到角色锚点（贴纸盘）的交互全部复用现成逻辑，本 plan 不碰。

## 1. 为什么造贴纸能大量复用

- **生成管线现成**：`orchestrator.generateIconAsset(visualDescription)` 已经就是
  「扁平贴纸图 → 绿幕抠图 → 程序加白 die-cut 边 → `store.putAsset` 返回资产哈希」，
  这正是贴纸要的样子（造角色选项图标 P3 就用它）。造贴纸 = 复用它 + 包一个 `mount:'edge'` ItemDef。
- **引导会话现成**：`openCreationSession`/`advanceCreation` 已按 `CreationGoal` 分派 guide 与生成，
  加一个 `'sticker'` 分支即可；图标卡 UI、扣花、WS 协议 goal-agnostic，照搬。
- **放置/附着交互现成**：造出的贴纸只要是 `mount:'edge'`，放置模式（`world._begin_placement`
  检测 `mount=='edge'` 吸附最近空边）、贴纸盘（character-anchors / self-stickers）、扣还背包、
  presence 转发，全部复用，零改动。

## 2. 唯一的真缺口：渲染取图只认打包资源

内置 12 款贴纸 renderRef 是 `sticker:<name>`，客户端一律 `PackRegistry.load_resource(name)` 按打包名取图：
- 边缘贴纸：`chunk_manager.gd:751`（`_scatter_kind`，同步建 QuadMesh + 材质）
- 边缘贴纸护栏：`chunk_manager.gd:365` `PackRegistry.category(skey) != "sticker"` → 非打包一律跳过
- 角色锚点贴纸：`world.gd:2994` `_sticker_tex`（`PackRegistry.load_resource`）

造出的贴纸**没有打包资源、只有网络资产哈希**。客户端已有按哈希拉图能力
`api.fetch_texture(hash)`（9+ 处在用，含立绘），缺口只是把它接进这两处取图路径。

**难点（P3）**：`_scatter_kind` 批处理路径是**同步**的，`api.fetch_texture` 是**异步**的。
方案：renderRef 用 `sticker:@<hash>` 约定 —— skey 以 `@` 打头即资产贴纸；
- 护栏放开：`skey.begins_with("@")` 视为合法贴纸，跳过 PackRegistry category 检查；
- `_scatter_kind` 遇 `@hash`：先建占位（1×1 白 quad / 透明），发起 `api.fetch_texture` 异步拉取，
  到手后回填材质 `albedo_tex` 并按贴图宽高比修 QuadMesh（缓存 hash→tex，避免重复拉）。
- `_sticker_tex`（角色锚点）本就在 async 上下文调用链（`_on_character_attach`/`_apply_attachments`），
  直接 `await api.fetch_texture(hash)` 即可，较简单。

## 3. 服务端垂直切片

### 3.1 类型与路由（P1）
- `CreationGoal = 'character' | 'prop' | 'sticker'`（types.ts）。
- routeIntent 加 `create_sticker` 命令（mock 关键词 + openrouter prompt）：
  「做个贴纸 / 贴纸 / 画个贴画」等 → `create_sticker`，params.description 保留原话。
- voice.ts：摘 `create_sticker` 命令 → `response.stickerRequest`（与 prop/character 并列）。
- server.ts 入口：`response.stickerRequest` → `openCreationSession(..., 'sticker')`。

### 3.2 图标库与引导（P1）
- `sticker_creation_options.ts`（与 prop_creation_options 平行）：
  - 问两类 `['kind', 'color']`：kind=图案（stk_ 前缀新图标），color 复用造角色 color 图标库。
  - `STICKER_OWN_OPTIONS`（kind 图案）：太阳/花/星星/爱心/彩虹/蝴蝶/月亮/笑脸 等，`stk_` 前缀。
  - `STICKER_ICON_PROMPTS`：每个图案的英文扁平贴纸生图主体（无脸/无手脚，符号化）。
  - `STICKER_CREATION_ASK` / `composeStickerDesc` / `findStickerOption` / `stickerOptionsByCategory` / `stickerIconPrompt`。
- `guideSticker(state, childInput)`（LLM 接口，mock + openrouter）：问 图案 + 颜色，
  凑够 kind（+可选 color）或超轮/「就这样」即 done，产出中文 description。与 guideProp 同形。

### 3.3 生成管线（P2）
- `designSticker(intentText): Promise<{ name, prompt }>`（LLM，mock 确定性）：
  中文汇总 → 贴纸中文名 + 英文扁平贴纸生图 prompt（喂 generateIcon）。
- `createStickerAsync`（server.ts，与 createPropAsync 平行）：
  扣花 → `sticker_pending` → 审核 description → `designSticker` → `generateIconAsset(prompt)` 得 assetHash →
  `creationStickerDef(worldId, id, name, assetHash)`（`mount:'edge'`, renderRef `sticker:@<hash>`,
  footprint 1×1, blocking:false, pathOk:true, wander:0）→ `store.upsertItem` + `store.bagAdd` →
  `item_created` 推送（复用造物的落地路径：客户端进背包，摆放走放置模式）。
  失败退花 + `sticker_failed`（与 prop_failed 同形）。
- `advanceCreation` done 分派：`goal==='sticker'` → `createStickerAsync`；summarize 用 `composeStickerDesc`。
- `newCreationState('sticker')`、`openCreationSession` goal 透传。

## 4. 客户端（P3）
- 渲染取图两处 + 护栏（见 §2 难点）。
- 图标卡/放置/贴纸盘 UI 零改动（goal-agnostic）。
- headless 冒烟：造贴纸会话跑通 + 资产贴纸渲染不崩。

## 5. 图标资产（P4）
- 造贴纸图案 kind 图标（`stk_*`）走图标生成管线（同造角色 P3），填 `iconAsset`。
- color 复用造角色已生成图标。

## 6. 与在飞 worktree 的关系
- `self-stickers`（贴自己，Player.attachments）在飞、未 merge：本 plan 从 main 分支，
  含 NPC 贴纸盘（character-anchors，已在 main）+ 放置模式（已在 main）；
  「贴自己」的 attach 交互属 self-stickers，本 plan 只保证渲染取图支持资产哈希，
  self-attach 渲染 self-stickers merge 后自然受益（同一 `_sticker_tex` 路径）。
- presence 冲突面注意：本 plan 不改 presence，规避冲突。

## 7. 验收（P5）
- server 单测全绿（新增 sticker 路由/guide/create 用例 + 不回归 prop/character）。
- headless 全绿。
- 真机手感留老板。
- `git merge --no-ff prd/fairy-stickers` 回 main（老板验收门）。
