# 内容分发架构：静态资产从 APK 搬到可下载的 `.pck` 内容包

## 目标

**一次发版，之后不重发 APK 就能持续推新内容**（模型/主题/地形/语音）。分发范围最大化：模型/贴图/音频/语音/字体都可下载分发，二进制只留"硬地板"。

**分发 ≠ 在线**：下载内容落 `user://` 后**永久本地、永久离线**，启动即挂载，不联网流式。表现与"打进包里"一致，只是交付方式从"烤进 APK"换成"首次联网拉一次"。

## 技术路线：`.pck` 资源包运行时挂载（非运行时 glTF 解析）

- ❌ **运行时解析 glb 字节**（`GLTFDocument`）：全仓零先例；撞 Godot 运行时导入已知坑——LOD/阴影网格/切线/VRAM 压缩不复现、外挂贴图丢失、破坏 `chunk_manager` 的 MultiMesh 合批假设。
- ✅ **`.pck` 资源包运行时挂载**（`ProjectSettings.load_resource_pack`）：每个内容包导出为版本化 `.pck`，主包导出时**排除**其资产；客户端下载+挂载后，`res://` 路径自动解析到挂载包里——**`PackRegistry` 一行不用改**（`pack_registry.gd:108` `load(path)` 语义不变），导入管线/LOD/贴图/合批全保留。

## P1 已证结论（isolation 实测，2026-07-23）

用 city 主题（12 栋建筑，glb 引用外挂贴图 `Textures/colormap.png`）做样，全部实测：

1. **挂载机制成立**：一个**从没有 city 源资产的空 Godot 工程**，`load_resource_pack("city.pck")` 后 `ResourceLoader.exists("res://assets/city/building-a.glb")=true`、`load()` 返回 PackedScene、实例化出 MeshInstance3D，**外挂贴图 colormap 也随之带入**（albedo_texture != null）。
2. **选择性包含**：导出预设 `export_filter="resources"` + `export_files=[城市 glb...]` → 产出 `city.pck` 只含 city（872K），依赖贴图自动带入。
3. **选择性排除**：`export_filter="exclude"` + `export_files=[building-a]` → 挂载后 building-a `exists=false`/`load=null`（真被剔除），building-b 仍在。
4. **⚠️ 坑：`exclude_filter` 的 glob 剔不掉已导入资源**——排除 `*skyscraper*` 后 glb 仍在包里。include/exclude 的 glob **只作用于非资源文件**（这也是为什么 `.mltr` 靠 `include_filter` 塞进包）。要从主包排除被分发的 glb/贴图，**必须用 `export_filter="exclude"` + `export_files` 列表，不能用 glob**。
5. **渲染一致是构造性保证**：挂载的 `res://assets/city/building-a.glb` 解析到与内置构建**同一个** imported `.scn` 文件（同 hash，`building-a.glb-003e8d29….scn`）——是同一份产物，非"看起来一样"。
6. **⚠️ 未挂载会崩**：`chunk_manager.gd:1095` 对 scatter 类直接 `scene.instantiate()`，`PackRegistry.load_resource` 返回 null（包没下载）时崩。架构上靠"进场景前先下载挂载"避免 null，另加防御性守卫（P3）。

## 分层

- **硬地板（留二进制）**：加载界面 UI/图标、intro 的地形+模型+旁白语音、麦克风授权语音、最小兜底字体子集。首次无网启动要能渲加载界面 + 跑完 intro。
- **pack 清单留二进制**：`assets/packs/index.json` + 各 `pack.json`（共 ~68K），客户端据此知道有哪些包、每个包引用哪些 glb；只有**重资产**（glb/贴图）走 `.pck` 分发。
- **可分发**：3D 主题模型、贴图、字体、voice/audio、非 intro 地形。

## 分发通道（复用现有基建）

- `.pck` 当内容寻址资产存入现有 `GET /assets/:hash`（`server/src/server.ts:873`，immutable+ETag），零新下载基建。
- 客户端 `user://` 内容寻址永久缓存（仿 `api.gd` `_cache_read/_cache_write`），命中不重下。
- manifest 端点：某 world/scene → 需要哪些包 `[{name,hash,bytes}]`。
- 预热器：进场景前拉 manifest → diff 已挂载/已缓存 → 下缺的 → 挂载 → 进场景；**下载在 onboarding 期就后台启动**（intro 播放时预取 village + 常用包，结束前就位，无加载墙）。
- 地形：已走 `.mltr` 字节路径（`TerrainMap.load_from_bytes`），天然可分发；3 个 committed `.mltr` 降为 intro 离线兜底。

## P2 已实现（服务端契约，2026-07-23）

服务端把 .pck 当内容寻址资产入库，并新增 manifest 端点告诉客户端某场景要哪些包。P3 预热器消费这两个契约。

**⚠️ 硬约束：服务端运行时读不到 `assets/packs/*.json`。** Docker 只 `COPY server/`（`server/Dockerfile`），
`assets/packs/` 在仓库根、不进镜像。所以 renderRef→pack 的映射【不能】运行时读 pack.json，必须在
**入库时**把每个包提供的渲染键随 .pck 一起登记进服务端注册表（部署脚本从 pack.json 读出 entries 键传入）。

**注册表**（`persistence.ts`，与 assets/spriteAnims 同款文件寻址 `packs.json`，进备份、跨重启）：
- `PackRecord = { hash, bytes, keys }`：`hash`=.pck 在资产库的内容寻址 hash（下载 URL `/assets/<hash>`）；
  `bytes`=字节数（客户端下载预算）；`keys`=该包 pack.json 的 entries 键（renderRef 冒号后段）。
- `registerPack(name, pck, keys)` → putAsset 入库 + 记录（幂等，同名覆盖）。`packForKey(key)` 反查所属包。
- `sceneManifest(worldId, sceneId)`：扫场景 terrain 矩阵 palette → 每个物品 `packKeyFromRenderRef(renderRef)`
  （`items.ts`，冒号后段；`sdf_inline`/`composed:`/`sticker:@hash` → null）→ `packForKey` → 去重。
  **只列已登记的包**：未登记键（未打包的主题、SDF props、造物）静默跳过 → 过渡期优雅缺失，客户端不崩。

**端点**：
- `GET /worlds/:wid/scenes/:sid/manifest` → `{ packs: [{name, hash, bytes}] }`（无鉴权，客户端要用；场景不存在 404）。
  实测：village → `[base]`（其余为 `sdf_res:`，不属任何包）；village_forest → `[base, toyroom]`（摆了 `furniture:table`/`bedSingle`）。
- `POST /admin/packs/:name`（配 `MALIANG_ADMIN_TOKEN`）body `{ pckBase64, keys }` → 入库 + 登记。与 fairy-sprite/
  admin/scenes 同 idiom（二进制走 base64-in-JSON，无需额外 body 解析器）。P5 部署脚本据此把全 15 包推上来。

测试：`server/test/content_packs.test.ts`（用真实 `assets/terrain/*.mltr` + 真实 pack.json 键跑端到端映射）。

## 导内容包命令

```bash
# 内容包（resources 模式，只含列出的资源 + 依赖）
/Applications/Godot.app/Contents/MacOS/Godot --headless --export-pack "<PackPreset>" <out>.pck
```

预设见 `export_presets.cfg` 的 `CityPack`（P1 样板）。P5 泛化到全主题时，主包（Android/macOS/iOS）改用 `export_filter="exclude"` 列出全部被分发资产。

## P5 已实现（泛化打包 + 非场景内容包下载机制，2026-07-23）

**范围（老板拍板「安全全量 ≈120M」）：** 分发 14 主题模型 + 5 册故事语音 + 物品念名语音 + bgm（除
carefree）。**保持硬地板**（各需独立高风险重构，留后续子 plan）：
- `assets/textures/terrain`（42M）——49 层入单个 `Texture2DArray` 启动全量加载（`terrain_textures.gd`
  `build_texture_array()`），排除任一层则整个数组构建失败、全局地形渲染崩。拆它要重构地形层索引契约。
- `assets/fonts`（25M）——默认 CJK 主题字体（`project.godot theme/custom_font`），不 subset 直接分发→
  无网首启全屏豆腐块。subset 需专门工具链。
- `bgm_carefree.wav`（26M）——菜单 `_ready` 即起播（`menu.gd:60`），硬地板。

**打包（单一真相来源）：** `scripts/gen-content-pack-presets.py` 从 `assets/packs/*/pack.json` + 目录扫描
生成 `export_presets.cfg` 的 21 个内容包预设 + 主包 `export_filter="exclude"` 排除列表（519 文件），
并输出 `build/packs/registry.json`（pack→{keys, export_path}）。`scripts/build-content-packs.sh` 逐包
`--export-pack`，`tools/verify_pack.gd` 挂载校验。要点：
- **主题包按整资产目录枚举资源**（glb/gltf/png/jpg/webp），与主包排除【对称】——杜绝外挂贴图漏排
  （roman 36M png 源、导入压缩后 22M 已验证进包）。gltf 的 .bin 几何由 Godot 导入烘进 .scn，源 .bin
  无需单列。
- **共享目录零冗余**：`assets/medieval`（medieval_town/kingdom/roman 共用）、`assets/furniture`
  （kitchen/toyroom 共用）——整目录打进各包，但**内容寻址天然去重**：同目录 → 同 .pck 字节 → 同 hash，
  服务端只存一份、客户端只下一次（实测 medieval_town/kingdom 同 hash `6d07739…`）。
- **故事册 lines.json**（非资源文件）走各故事包的 `include_filter` 显式打进包；主包 `exclude_filter`
  剔除 `assets/voice/story_*/lines.json`——未挂载时该册目录整体缺失 → `story_voice.gd _story_voice_dirs`
  不列 → `has_line=false` → 调用方回落 clientTts（优雅降级，零客户端改动）。

**非场景内容包下载机制（voice/bgm 不进场景 palette）：**
- 服务端 `GET /packs` → 全部已登记包 `name→{hash,bytes}`（`sceneManifest` 只列场景摆放引用的主题包）。
  `POST /admin/packs/:name` 放宽允许空 keys（voice/bgm 无渲染键）。
- 客户端 `api.gd fetch_packs_index()` 拉 `/packs`；`world._prefetch_content_packs()` intro 期后台按包名
  预取 `bgm`+`voice_*`（会话级闸 + 内容寻址永久缓存），接在 `IntroDirector._prefetch_packs_bg` 的
  `_prewarm_packs` 之后。best-effort：拉不到不影响主线。
- **各加载点优雅降级**（缺包 = 未下载/未挂载）：story 语音走 `has_line`→TTS；item 念名走
  `ResourceLoader.exists`→edge_tts；**bgm 段缺失守卫**（`game_audio.gd _poll_bgm_load`，test-first
  `test_bgm_missing_step`）——修复前任一段 load 失败即 clear 全部→无任何 BGM（含 carefree）；改为跳过
  失败段只播成功段，carefree 照放。

**入库：** `scripts/register-content-packs.py <server-base>` 从 registry.json 读 keys、base64 POST 全 21 包。
本地实测：21/21 入库、`GET /packs` 返回 21。prod 部署等老板。

**⚠️ 未验（编辑器局限 + APK 硬坎）：** 「缺包→下载→挂载→prop 出现」完整离线闭环**只能在导出包上真验**
——编辑器 `res://` 是完整文件系统、所有资产都在、包永不「缺失」。且 APK 导出必须在主 checkout（worktree
缺 gitignored ASR→静默丢）。故 APK 体积前后对比 + 全链离线眼验 = **merge 回 main 后在主 checkout 导出**
时做（老板拍板此顺序）。worktree 内已验尽机制件：打包构建+校验、服务端 register+/packs、客户端预取+
bgm 守卫 test-first、headless 套件。
