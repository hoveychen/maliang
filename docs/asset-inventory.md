# 马良小世界 — 资源全景图

盘点日期 2026-07-10。所有体积为实测值（`du -sh` / `find | wc -l`），非估算。

一句话总览：**美术与语音的"固定资产"随 APK 发；玩家玩出来的东西（角色立绘、idle 动画、NPC 语音）在服务端按内容寻址存，客户端运行期下载并永久缓存。**

---

## 一、客户端（随 APK 打包）

### 1.1 `assets/` — 共 39M

| 目录 | 体积 | 内容 | 引用方 |
|---|---|---|---|
| `assets/ui/` | 13M | 63 个 PNG：背景、图标 `ic_*`、情绪 `em_*`、引导选项 `opt_*`、贴纸 `st_*`、印章 `stamp_*` | 各 UI 脚本 |
| `assets/audio/` | 8.6M | 16 ogg + 1 wav。大头是 `bgm/bgm_main.wav`（8.4M）；其余是 Kenney UI 音效与奖励音 | `scripts/game_audio.gd` |
| `assets/voice/` | 7.6M | **47 条预制 WAV**：`fairy/` 20 条 + `onboarding/` 27 条，各带 `lines.json` 清单 | `scripts/fairy_voice.gd`、`scripts/onboarding.gd` |
| `assets/textures/` | 6.8M | 4 张水彩地形贴图（dirt / grass / stone / water） | `shaders/terrain_ground.gdshader` |
| `assets/kaykit/` | 848K | 19 个 glTF 低模（森林 13 + 村庄建筑 6），分离式 `.gltf`+`.bin`，共享贴图 | 世界生成 |
| `assets/icons/` | 444K | 3 张 Android 启动图标 | `export_presets.cfg` |
| `assets/sdf_props/` | 136K | 14 个 SDF 道具 JSON 定义 + 4 个预烘焙 `.res` | `scripts/sdf_*.gd` |
| 散图 | ~1M | `fairy.png`(720K)、`fairy_idle.webp`(260K)、`critter.png`(96K) | 仙子立绘与 idle 图集 |

### 1.2 代码与着色器

只有 4 个 `.tscn`（`main` / `menu` / `onboarding` / `loading`，都是几百字节的薄壳）——世界与 UI 几乎全在 GDScript 里搭。`shaders/` 88K，9 个 `.gdshader`：`sdf_field` / `sdf_blend_shell` / `sdf_outline` / `terrain_ground` / `water_surface` / `sky_day` / `paper_character` / `paper_xray` / `blob_shadow` / `world_bend`。

### 1.3 Gitignored 但打包必需 ⚠️

clone 之后不跑脚本，APK 打不出来、或者静默丢掉端侧 ASR：

| 路径 | 大小 | 怎么拿 |
|---|---|---|
| `android/`（Godot 自定义 gradle 模板） | 源模板 ~289M | Godot 编辑器「安装 Android 构建模板」 |
| `addons/maliang_asr/bin/*.aar` | 56M + 54M | `scripts/build-asr-plugin.sh` |
| `asr_plugin/src/main/assets/asr-models/` | ~73M（encoder/decoder/joiner + tokens.txt） | 构建脚本下载 |
| `.keystores/` | — | 本地保管，release 签名必须复用同一把 key |

APK 的"重量"来自 Godot 库模板 AAR + 端侧 ASR 模型，不是美术素材。

### 1.4 运行期下载 → `user://` 缓存

`scripts/api.gd` 负责，缓存目录 `user://asset_cache/<hash>`，**内容寻址，永不失效**：

| 内容 | 拉取函数 | 格式 |
|---|---|---|
| 角色 / 村民立绘 | `fetch_texture()` | PNG（静态）/ WebP（图集），按 magic bytes 分流 |
| idle 动画图集 | `fetch_sprite_anim()` | WebP sprite-sheet |
| 服务端 TTS 音频（降级路径才用） | `fetch_audio()` | 裸 PCM，采样率从 content-type 解析 |

其余 `user://` 本地状态：`profile.json`（玩家档案，含 `spriteAsset`）、`quality.cfg`（画质档位）、`perf_sweep`（debug 标记）。

---

## 二、服务端

### 2.1 SQLite —— `<dataDir>/world.db`

引擎是 Node 内置 `node:sqlite`。线上 `dataDir = /workspace/data`。

| 表 | 存什么 |
|---|---|
| `players` | 设备 UUID 身份（无鉴权） |
| `worlds` | 世界 + 钱包（`inventory` 列存 Wallet JSON）+ 进行中委托 |
| `characters` | Character 整对象 JSON（含 `voiceId` / `greetingStyle` / `appearance.spriteAsset`） |
| `props` | 语音生成的 SDF 物件 |
| `memories` | NPC × 玩家长期记忆 |
| `visits` / `chat_turns` | 会话段与对话历史（按 NPC×玩家裁到 40 轮） |
| `creation_icons` | 引导造角色 `option_id → asset_hash` |

### 2.2 资产系统 —— 内容寻址文件

不是 DB blob。寻址 = **SHA-256 前 16 个 hex 字符**。

- 落盘：`<dataDir>/assets/<hash>`（裸二进制）
- 清单：`<dataDir>/assets.json`（`hash → mime`）、`<dataDir>/sprite_anims.json`（立绘 hash → 动画记录）
- 出口：`GET /assets/:hash`（`server.ts:349`）

"类型"只体现在引用它的字段，不是独立命名空间：`spriteAsset`（立绘）/ `animAsset`（idle 图集）/ `iconAsset`（造角色图标）/ `ttsAsset`（合成音频）。

### 2.3 运行期生成的资源

| 资源 | 模块 | 外部服务 |
|---|---|---|
| 角色设定 spec | `adapters/openrouter_llm.ts` | OpenRouter，`qwen/qwen3.6-flash` |
| 角色立绘 | `adapters/openrouter_image.ts` | OpenRouter，`google/gemini-3.1-flash-image` |
| 立绘抠图 / 裁边 | `adapters/chroma_cutout.ts` | 本地洪水填充算法 |
| 立绘朝向检测 | `adapters/openrouter_orientation.ts` | OpenRouter vision |
| idle 动画视频 | `idle_animation.ts` | Seedance `bytedance/seedance-1-5-pro` |
| 视频 → sprite-sheet | `sprite_sheet.ts` | 本地 ffmpeg 抽帧 + 抠绿 + cwebp |
| TTS（降级路径） | `voice.ts` + `adapters/minimax.ts` / `local.ts` | MiniMax → 本地 Kokoro → 讯飞 → mock |
| ASR | `adapters/local.ts` | 本地 sherpa Zipformer 流式 |
| 文本审核 | `adapters/openrouter_moderation.ts` | OpenRouter `moonshotai/kimi-k2.6` |

### 2.4 本地模型 `server/models/` —— 736M

gitignore 不入库，容器启动时 `scripts/fetch-voice-models.sh` 幂等拉取到持久卷。Kokoro TTS 408M + sherpa Zipformer ASR 328M。

### 2.5 管理台

`server/admin/` 是 React + Vite，构建产物 `admin/dist/`（268K）由 `@fastify/static` 挂到 `/debug/`，`MALIANG_ADMIN_TOKEN` 门禁。注意 `server/` 用 npm、`server/admin/` 用 pnpm。

### 2.6 持久卷

**只有 `/workspace` 一个卷**（muvee 平台约定，`Dockerfile:37-38`）。里面是 `data/`（SQLite + 内容寻址资产）与 `models/`（语音模型）。

### 2.7 全量备份 / 恢复

数据只有持久卷这一个落点，卷没了就全没了。管理台 `/debug#/data` 页是唯一的兜底：

| | 端点 | 做什么 |
|---|---|---|
| 导出 | `GET /admin/backup` | 流式下发 `.tar.gz`：`world.db`（**`VACUUM INTO` 一致性快照**，在线安全）+ `assets/` 全量 + `assets.json` / `sprite_anims.json` / `manifest.json` |
| 导入 | `POST /admin/restore` | 上传包 → 解到同卷临时目录校验（版本 / 必需文件 / 是不是马良的库）→ 把当前数据另存成 pre-restore 兜底包 → `rename` 原子换目录 → `store.reload()`（**不用重启进程**） |

几个刻意的选择：

- **不含 `models/`**（736M）。启动脚本 `fetch-voice-models.sh` 幂等重下，备它纯属浪费。
- **`VACUUM INTO` 而不是拷文件**：`node:sqlite` 没有 `.backup()`（v26.4 上是 `undefined`），直接 tar 正在写的 db 会拿到撕裂快照。
- **两份清单从内存态序列化**，不拷 dataDir 里的文件——清单是非原子的全量 `writeFileSync` 重写，拷文件可能读到半截 JSON。
- **门禁比 `/debug` 更严**：未配 `MALIANG_ADMIN_TOKEN` 时这两个端点直接关闭（`debugAuthed` 在无 token 时是放行的，那条规则套在 restore 上等于把删库按钮挂公网）。
- 包坏了/版本不对，在**覆盖之前**就被拒绝，现网数据一个字节不动。

**没有对象存储（minio 之类），也不需要**：资产已经是内容寻址（SHA-256 前 16 位当文件名），去重与不可变本来就有了；几十 MB、单容器、无 CDN 的规模下，加一个对象存储等于多养一个同样会丢数据的有状态服务。真要上，触发条件是多实例横向扩展 / 资产上 GB 级 / 接 CDN。

### 2.8 资产字节按需读盘（不再全量常驻内存）

`WorldStore` 启动时**只加载清单**（`#assetMime`，hash → mime，每条几十字节）；资产**字节**等到 `getAsset` 取用时才回源读盘，放进一个 **32MB 封顶的 LRU**（`#assetCache`），超预算就驱逐最久未用的。

以前是启动时把 `assets/` 下每个文件都 `readFileSync` 进内存 Map——常驻内存随资产数线性增长。实测同一份生产数据（122 个资产 / 70MB / 15 角色），构造 store 的 RSS 增量：

| 实现 | 常驻内存 |
|---|---|
| 旧（启动全读进 Map） | **136.8 MB** |
| 新（清单 + 按需读盘 + LRU） | **2.4 MB** |

⚠️ **内存 store（`dataDir=null`，测试用）永不驱逐**：那里 LRU 是字节的唯一落点，没有磁盘可回源，驱逐一张就等于把数据弄丢了。改这段代码时务必保留这个分支。

---

## 三、语音音色链路（edge-tts 切换后）

### 3.1 三条路，只有一条跟着角色音色走

| 场景 | 音频从哪来 | 跟 `voiceId` 走吗 |
|---|---|---|
| NPC 对话 / NPC 打招呼 | 客户端 `scripts/edge_tts.gd` 直连微软实时合成 | ✅ 是 |
| 仙子台词（招呼 / idle / 奖励 / POI） | `assets/voice/fairy/*.wav` 预制 | ❌ 否，构建期烧死 |
| Onboarding 旁白 | `assets/voice/onboarding/*.wav` 预制 | ❌ 否，构建期烧死 |

预制音频天然不可能"跟着音色走"——它在构建期就固化了一个音色。问题不在于它固定，而在于**固定的那个音色是否等于该角色运行期的音色**。

### 3.2 音色权威表

- 目录：`server/src/voice_catalog.ts` —— 11 个 edge 原生音色，其中 4 个 `main: true` 进主力池。
- 角色音色由创建时 LLM 按性格挑（`openrouter_llm.ts`），非法值回落 `fallbackVoice()` = SHA1(id) 对主力池取模，**同一 id 永远同声**。
- 仙子固定 `FAIRY_VOICE = 'zh-CN-XiaoyiNeural'`。
- 客户端 `edge_tts.gd:map_voice()`：`zh-` 前缀直通；legacy 名（MiniMax `lovely_girl` / Kokoro `zf_*`）查表映射；未知按 hash 落池。

### 3.3 一致性核对结果

| 预制目录 | `lines.json` 的 `voice` | 该角色运行期音色 | 一致？ |
|---|---|---|---|
| `assets/voice/fairy/` | `zh-CN-XiaoyiNeural` | `FAIRY_VOICE` = `zh-CN-XiaoyiNeural` | ✅ |
| `assets/voice/onboarding/` | `lovely_girl`（MiniMax 童声） | 说话人是仙子 → `zh-CN-XiaoyiNeural` | ❌ **不一致** |

Onboarding 那 27 条是 MiniMax 时代（commit `a443d0d`）合成的；后来 `6cdb5b6` 把仙子的 20 条换成了 edge Xiaoyi，**onboarding 漏了**。结果是同一个仙子，引导流程里一个声音，进世界后换成另一个声音。

附带影响：`server/tools/gen_voice_lines.mjs` 现在是 edge-tts 版，会把 `lines.json` 的 `voice` 原样塞进 SSML 的 `<voice name='...'>`。对 onboarding 目录重跑会拿 `lovely_girl` 去请求微软，直接失败。

### 3.4 生成器

`server/tools/gen_voice_lines.mjs`：读 `<目录>/lines.json` → 逐条 edge-tts 合成 mp3 → ffmpeg 转 PCM16 单声道 WAV。幂等，`--force` 全量重生。
