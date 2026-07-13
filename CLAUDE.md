# maliang

幼儿园儿童语音沙盒游戏。Godot 4.6.3 客户端（GDScript）+ Node/TypeScript 服务端。

## 导 Android APK：只用 `scripts/export-apk.sh`

**不要**直接跑 `godot --export-debug "Android" ...`。有两个坑，两个都是静默的：

1. **Godot 版本**：`PATH` 里的 `godot` 是 4.6.1-mono，和 Android 构建模板（4.6.3）对不上，导出直接失败。必须用 `/Applications/Godot.app`。
2. **端侧 ASR 会被静默丢掉**：ASR 依赖的东西全是 gitignored 产物——`android/`（`.gitignore:3`，含 AAR 插件）和 `asr_plugin/src/main/assets/`（`.gitignore:22`，内嵌的 sherpa 模型）。**干净 checkout / git worktree 里一个都没有**，而 Godot 缺了它们**不报错**，只吐一条 warning，exit code 照样是 0。

所以：**APK 必须在主 checkout 导，不能在 worktree 里导**。脚本会在导出前拦住这种情况，并在产物上数 onnx / tokens.txt / sherpa 库，缺了就 exit 1。

装机后核一下设备端 md5 与本地一致——华为有 `install -r` 装回旧包的前科。

（运行期还有 `AsrGuard` 兜底：Android 上缺 ASR 会全屏阻断、拒绝进游戏，所以坏包不会流到小朋友手里。但那是装到真机、启动、撞红字之后才知道——脚本让你在导出当场就知道。）

## 导 iOS：只用 `scripts/export-ios.sh`

同样**不要**直接跑 `godot --export-debug "iOS"`——iOS 有一个和 Android 同源、但更阴的静默坑：

**Godot 会把 ASR 模型静默丢掉。** `.gdextension` 的 `[dependencies]` 能把 sherpa/onnxruntime 的
xcframework 搬进 Xcode 工程并链接，但同一机制搬**模型目录**时，Godot 把它塞进了 pbxproj 的
**Frameworks** build phase——Xcode 对着一个普通目录不报错、不链接、也不打进包。实测：导出
exit 0、`xcodebuild` BUILD SUCCEEDED、`.app` 里连 `tokens.txt` 都没有。

脚本导出后会修补 pbxproj（把模型引用挪到 Resources phase），然后**试编一遍真机包**，在 `.app`
里数 onnx（应为 3）、查 `tokens.txt`、`nm` 查 `_maliang_asr_library_init` 入口符号，缺了 exit 1。
「工程里有」不等于「包里有」——只有最后这道 `.app` 检查算数。

```bash
scripts/export-ios.sh debug     # 或 release
open build/ios/maliang.xcodeproj   # Xcode 选真机 → Run（team 6HU93XQG5B）
```

其它约束：
- iOS 上端侧 ASR 是硬依赖（`AsrGuard`），和 Android 同档：缺了全屏阻断、拒绝进游戏。
- 模拟器走不通（官方 ios.zip 的 simulator 切片链不出 arm64 `_main`），只能真机。
- 最低 iOS 15.1（sherpa 带的 onnxruntime 要求），低于此 xcodebuild 会告警。

## 服务端部署

`git push` 触发 GHA 构建镜像，但 **auto-deploy 是关的**——构建绿了不等于上线，必须手动：

```bash
muveectl projects deploy 0ec0addb-810f-43d0-9d0d-1f704ca38225   # maliang-server
```

验证真的换上了新代码（别只看构建绿）：

```bash
muveectl projects curl 0ec0addb-810f-43d0-9d0d-1f704ca38225 /health   # version 应等于你刚 push 的 commit sha
```

## 测试

- 服务端：`cd server && npm test`（node:test）+ `npx tsc --noEmit`
- 客户端：`scripts/test-headless.sh`（Godot headless，退出码=失败数）。新增测试要注册进这个脚本，否则不会被跑到。

## 小仙子（fairy）的一条硬约束

她**不会走路**，这是三层刻意封死的设计，不是遗漏：服务端 `LOCOMOTION_ABILITIES` 对 `isFairy` 剔除（`server/src/types.ts:26`）、客户端 `_run_behavior` 对 `is_fairy` 早返回（`scripts/world.gd`）、stage 命令对她早返回。

原因：给她 `move_to`，LLM 就会说「好呀，我们去风车那儿」然后人纹丝不动——孩子听见了承诺，看见的是原地发呆。**与其在下游拦，不如源头不给。**

她唯一的位移是**引路**（`guide_to`，见 `docs/fairy-guide-design.md`）：走路的是小朋友，她只飞在前面领、回头等，不碰 `BehaviorExecutor`，也不碰玩家的 avatar。要给她加新能力时，先想清楚它需不需要「她走过去」——需要就别加。
