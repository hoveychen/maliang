# macOS 端侧 ASR 可行性调研

**背景**：Android 已用 sherpa-onnx Zipformer 跑端侧 ASR，macOS 仍走服务端识别（讯飞）。目标是让 macOS 也端侧化，进而**废弃服务端的讯飞依赖**。

**结论：可行，且工作量比预期小。** 主要成本集中在 GDExtension 的构建与打包链路，而非算法或接口设计。

调研日期 2026-07-10，对应 sherpa-onnx v1.13.3 / Godot 4.6.3 / godot-cpp master(v10, Beta)。

---

## 1. 三个待答问题的结论

### 1.1 sherpa-onnx 的 macOS 库形态

官方 release 直接提供 macOS 预编译产物，无需自己编译。端侧只需 ASR，可取 `-no-tts` 变体：

```
sherpa-onnx-v1.13.3-osx-universal2-shared-no-tts-lib.tar.bz2   29MB（压缩）
```

解包后（已实测下载解包）：

| 文件 | 大小 | 说明 |
|---|---|---|
| `libsherpa-onnx-c-api.dylib` | 6.0MB | C API，universal2 |
| `libonnxruntime.dylib` | 53MB | 推理后端 |
| `libsherpa-onnx-cxx-api.dylib` | 287KB | C++ 封装，可不用 |

`lipo -info` 确认 `x86_64 arm64` 双架构。头文件在源码树 `sherpa-onnx/c-api/c-api.h`（v1.13.3 tag 下 HTTP 200）。

**C API 符号与现有 Kotlin 插件一一对应**（`nm -gU` 实测）：

| Kotlin 插件方法 | 对应 C API 符号 |
|---|---|
| `initialize()` | `SherpaOnnxCreateOnlineRecognizer` |
| `startSession()` | `SherpaOnnxCreateOnlineStream` |
| `feedPcm()` | `SherpaOnnxOnlineStreamAcceptWaveform` + `SherpaOnnxIsOnlineStreamReady` + `SherpaOnnxDecodeOnlineStream` + `SherpaOnnxGetOnlineStreamResult` |
| `stopSession()` | `SherpaOnnxOnlineStreamInputFinished` |

即 [MaliangAsrPlugin.kt](../asr_plugin/src/main/java/cc/insnap/maliang/asr/MaliangAsrPlugin.kt) 那 137 行是逐行可直译的，无需重新设计。

### 1.2 模型复用：完全复用，零新增

Android 端侧、服务端 `local` provider 用的是**同一套权重**：

```
sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12
├── encoder-...int8.onnx   67MB
├── decoder-....onnx        4.9MB
├── joiner-...int8.onnx     1.0MB
└── tokens.txt              18KB       合计 73MB
```

- Android：打进插件 AAR 的 assets（[build-asr-plugin.sh](../scripts/build-asr-plugin.sh)）
- 服务端：`server/models/` 下同名目录，由 `sherpa-onnx-node` 加载（[local.ts:149](../server/src/adapters/local.ts#L149)）
- `build-asr-plugin.sh` 已经优先复用 `server/models/` 里的同款模型，不重复下载

macOS 复用这同一份即可。**三个运行时共享一份权重 → 识别行为天然一致**，兜底逻辑和 prompt 只需调一遍。

### 1.3 GDExtension 包装成本

**有现成的参考实现可抄。** [PhilNikitin/godot-kokoro](https://github.com/PhilNikitin/godot-kokoro)（★18）是 Kokoro TTS 的 Godot GDExtension，走的正是 sherpa-onnx C API，且**已经解决了 macOS 打包**：

```
addons/godot_kokoro/bin/libgodot_kokoro.macos.template_debug.framework
addons/godot_kokoro/bin/libgodot_kokoro.macos.template_release.framework
addons/godot_kokoro/bin/libsherpa-onnx-c-api.dylib
addons/godot_kokoro/bin/libonnxruntime.1.23.2.dylib
godot_kokoro/SConstruct
godot_kokoro/src/register_types.cpp
addons/godot_kokoro/godot_kokoro.gdextension
```

同一个 `libsherpa-onnx-c-api.dylib`、同一个 onnxruntime、macOS `.framework` 打包方式、`.gdextension` 写法——全部可参照。差异只是把 `OfflineTts` 换成 `OnlineRecognizer`。

另有 [ClawfficeOrg/careless-whisper-godot](https://github.com/ClawfficeOrg/careless-whisper-godot)，证明 **Godot 4.6 + GDExtension + 端侧 ASR** 的组合已有人跑通（用 whisper.cpp）。

---

## 2. 最关键的发现：客户端一行都不用改

端侧 ASR 在 GDScript 侧是 **duck-typed 单例**，客户端从不依赖 Android 特有的类型：

```gdscript
# world.gd:3683
if not Engine.has_singleton("MaliangAsr"): ...
_asr_local = Engine.get_singleton("MaliangAsr")
```

整个接口面只有 **5 个方法 + 4 个信号**：

| | |
|---|---|
| 方法 | `initialize` / `isReady` / `startSession` / `feedPcm` / `stopSession` |
| 信号 | `asr_ready` / `partial_result` / `final_result` / `asr_error` |

PCM 采集也已经统一：Kotlin 插件注释写明 `16kHz 单声道 PCM16LE 分片（与服务端 voice_chunk 同一采集源）`。

**因此**：只要 GDExtension 注册一个同名 `MaliangAsr` 单例、暴露同名方法与信号，[world.gd](../scripts/world.gd) 和 [onboarding.gd](../scripts/onboarding.gd) **零改动**——`Engine.has_singleton("MaliangAsr")` 在 macOS 上自然返回 true，现有分支逻辑直接生效。

唯一需要改的一行在 [asr_guard.gd](../scripts/asr_guard.gd)：

```gdscript
static func asr_required(os_name: String) -> bool:
	return os_name == "Android"          # → os_name in ["Android", "macOS"]
```

副作用是好的：GDExtension 在**编辑器和 headless 里也会加载**（Android 插件做不到），所以 headless 测试首次能覆盖真实的端侧 ASR 路径。

---

## 3. 讯飞退役：**服务端早已不走讯飞了**

生产容器 runtime-logs 实锤（`muveectl projects runtime-logs`）：

```
全部模型就绪：/workspace/models
语音：ASR=local TTS=minimax（speech-2.6-turbo，失败回落本地 Kokoro）
```

原因：[Dockerfile:48](../server/Dockerfile#L48) 的 CMD 在**容器启动时**就跑 `fetch-voice-models.sh` 把模型拉进 `/workspace/models`（持久卷），于是 `VOICE_ASR_PROVIDER` 压根没设、`auto` 探到模型直接落 `local`。

生产 env 里 `XFYUN_APP_ID` / `XFYUN_API_KEY` / `XFYUN_API_SECRET` 三个变量仍挂着，但**代码路径不经过它们**：

- `XfyunASRAdapter` — 已被 `local`（sherpa-onnx-node，同一套 Zipformer 权重）取代
- `XfyunTTSAdapter` — TTS auto 落点是 `minimax → local(Kokoro) → xfyun → mock`，实际落在 minimax

**所以「切到 local」这一步不存在，它早就发生了。** [xfyun.ts](../server/src/adapters/xfyun.ts)（203 行）+ 两个测试文件已是死代码，可直接删除。

### 兜底不会变哑巴

有人会担心：拔掉 xfyun 后若模型缺失，`auto` 会落到 `mock`（哑巴）。不会——[Dockerfile:48](../server/Dockerfile#L48) 是

```sh
./scripts/fetch-voice-models.sh "$VOICE_MODELS_DIR" && exec node src/index.ts
```

模型拉取失败则 `&&` 短路，容器根本不启动，不存在"静默降级成 mock"的路径。

## 3.1 实测：流式 ASR 的 CPU 开销（关键数据）

切换前最大的顾虑是"服务器 CPU 扛不扛得住"——毕竟 ZipVoice TTS 在 2 核服务器上要 8–9s。

**实测结论：ASR 与 TTS 完全不是一个量级。** 复用生产的 `LocalASRAdapter`（`numThreads=2`、`provider=cpu`、`greedy_search`），按 150ms 批流式喂模型自带的 6 段真实中文音频（共 26.52s）：

| 指标 | 值 |
|---|---|
| 模型加载 | 1149ms（一次性） |
| 墙钟 RTF | **0.031** |
| CPU-RTF | **0.081** |
| 折算 | 识别 1 秒语音 ≈ **81ms CPU 时间** |

单条 RTF 稳定在 0.029–0.034，识别文本正确（如「重点呢想谈三个问题首先就是这一轮全球金融动衡的表现」）。

**验证状态**：这是在 **Apple Silicon** 上实测的，不是生产 x86 容器。生产容器无法进入跑基准——`muveectl projects exec` 报 `No such container: muvee-maliang-api`（已知的容器名解析坑）。即便 x86 慢 5 倍，CPU-RTF 也才 0.4，单核仍可实时处理 ~2.5 路并发。且生产本就在跑 `local`，`projects metrics` 显示空闲态 CPU 0%、内存 1.0GB / 3.67GB。

## 3.2 因此，真正剩下的工作

1. **删掉 `xfyun.ts`** 及其两个测试文件、`config.ts` 的 xfyun 字段、`factory.ts` 的 xfyun 分支——纯死代码清理
2. **macOS 端侧化**（第 1、2 节），让服务端 ASR 只剩测试用途

---

## 4. 成本与风险

### 体积

macOS `.app` 增量 ≈ **132MB**：dylib ~59MB（c-api 6.0 + onnxruntime 53）+ 模型 73MB。
若只发 arm64（放弃 Intel Mac），dylib 侧可再省一截。

### 工作量拆解

| 项 | 说明 |
|---|---|
| godot-cpp 接入 | master(v10) + `scons api_version=4.6` |
| C++ 实现 | ~150 行，Kotlin 那份的直译（executor → `std::thread` + 任务队列） |
| 构建脚手架 | SConstruct + `.gdextension` + `register_types.cpp`，照抄 godot-kokoro |
| 导出打包 | dylib 进 `.app/Contents/Frameworks`，签名 |
| GDScript 改动 | `asr_guard.gd` 一行 |

### 风险（诚实标注验证状态）

| 风险 | 状态 |
|---|---|
| godot-cpp master 是 **Beta** | 已核实（README 原文）。保守可用 `godot-4.5-stable` + GDExtension 前向兼容规则（旧 target 可在新引擎加载），但官方无 4.5→4.6 逐字保证 |
| macOS 代码签名 / 公证对 dylib 的处理 | **未验证**。godot-kokoro 产出了 `.framework` 说明它解决过，但我没读其签名配置 |
| sherpa 在 macOS 的中文识别延迟/准确率 | **未实测**。同模型同引擎、Android 已跑通 → 判断为低风险，但这是推断不是实测 |
| 生产 x86 容器内的 ASR 性能 | **未实测**（`projects exec` 撞容器名解析坑）。但 Apple Silicon 上 CPU-RTF=0.081，且生产本就在跑 `local` —— 见 §3.1 |

---

## 5. 建议路径

1. **删掉 `xfyun.ts`**——它已是死代码（§3），不是"迁移"而是清理，无风险
2. **macOS GDExtension**，照抄 godot-kokoro 脚手架；因为客户端零改动，风险集中在构建/签名而非逻辑

若只想验证 GDExtension 路线可行，最小实验是：拿 godot-kokoro 的 SConstruct + `.gdextension` 起一个空扩展，注册 `MaliangAsr` 单例并让 `isReady()` 返回 `false`，确认 Godot 4.6 能在 macOS 上加载它。这一步不碰 sherpa，能把「构建链路」和「识别逻辑」两类风险隔离开。
