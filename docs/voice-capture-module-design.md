# VoiceCapture 模块化设计（开放麦 + VAD + 端侧/服务端 ASR 编排收敛）

## 背景：现状是两份手抄副本

近身对话的「开放麦 → VAD 断句 → 端侧/服务端识别」这套编排，目前在两个地方**整段复制**：

- `scripts/world.gd`（~3760–4030 + `_process` 1439–1446 的 BGM 门控）——功能最全的一份。
- `scripts/onboarding.gd`（intro 名字步骤，~340–466 + `_process` 624–630）——精简子集。

底层积木**已经是模块**：`MicRecorder`（`mic_recorder.gd`）、`VoiceVad`（`voice_vad.gd`）、`AsrGuard`（`asr_guard.gd`）、`GameAudio`（`game_audio.gd`）。
但把它们串起来的**编排循环**没有收敛，两份各自维护、变量名漂移（`_local_asr_session` vs `_local_session`、`_flush_pending_chunk` vs `_flush_intro_chunk`、`_pending_pcm` vs `_intro_pending_pcm`……），注释里到处写着「同 world.gd」「与 world.gd 同节奏」——就是手抄的。

### 已经抄漏的一处（本次触发点）

`world.gd` 的 BGM 静音口径是 `InteractionFsm.music_muted = in_interaction and not speaking()`——**麦一开就静音，只在角色说话时才放音乐**，附 logcat 实证：满音量 BGM 峰值（rms≈0.05–0.085）会顶开 VAD、自己开录、ASR 转出空。

`onboarding.gd` 的副本停在旧口径 `set_music_muted(_intro_recording)`——**只在 VAD 已判定孩子开口、正在录时才静音**。于是名字步骤「旁白说完→开麦→等孩子开口」这段等待窗，BGM 满音量（连 duck 都没有）灌进无 AEC 的麦。这正是本次要修的 bug，也是「没模块化 → 口径漂移」的直接症状。

## 共享机械核 vs 宿主业务策略

把两份的交集抽成 `VoiceCapture`，分歧作为宿主注入的策略，保留在各自宿主。

### 归入 VoiceCapture（机械核，单一真相）

| 环节 | 现 world.gd | 现 onboarding.gd |
|---|---|---|
| 端侧单例接线 | `_setup_local_asr` + connect final/ready/error + AsrGuard fatal 门禁 | 同款照抄 |
| 就绪判定 | `_asr_is_ready` | 同款 |
| 每帧 mic drain + VAD feed | `_step_voice` | `_step_intro` |
| 自听防护 | `_unmute_t`(UNMUTE_GRACE 0.3s) + `sfx_bleeding` guard | 同款 |
| 分片节奏 | `_chunk_accum` ≥0.15s → flush | `CHUNK_FLUSH_SECS` 同款 |
| 端侧会话生命周期 | startSession/feedPcm/stopSession | 同款 |
| VAD 事件分发 | begin/speech/end/cancel | 同款 |
| mic on/off 音效 | play_sfx | 同款 |
| **BGM duck/mute 门控** | `set_ducked` + `set_music_muted`（麦开就静音） | **只 recording 静音（漂移点）** |
| 退场清理 | disconnect + mic.stop | `_exit_tree` 同款 |

### 留在宿主（作为策略注入 / 信号回调）

- **Sink（识别产物去向）**：world = WS 流式 `send_voice_start/chunk/end/cancel`；onboarding = 攒整段单发 `POST /onboarding/intro`。→ VoiceCapture 暴露 `chunk(pcm)` / `local_final(text)` / `committed(pcm)` 信号，由宿主决定往哪送。
- **开麦门禁**：world 用 `InteractionFsm.mic_open(FSM)`（含 thinking/speaking/cooldown/creation）；onboarding 用「在 intro 页且旁白不在播且未提交」。→ 宿主提供 `should_listen() -> bool` 回调，VoiceCapture 只负责「该听时喂、不该听时 reset」。
- **world 专属扩展**（不进模块）：空识别指数退避（`_empty_streak`/`_cooldown_t`）、喊话文本中继（`_talk_pid`）、造物投掷（`_throw_voice_answer`）、耗时打点（`_vt_*`）、`[vad]` logcat、think timer。
- **onboarding 专属扩展**：重问预制音频（`_intro_retry`）、名字确认流程、声波条 UI。

## 建议 API 形态（草案，P1 定稿）

`VoiceCapture extends Node`（像 `GameAudio` 一样 add_child，持有 `MicRecorder` 子节点、连 `MaliangAsr` 单例信号、持 `GameAudio` 引用做门控）：

```
signal utterance_begin()                 # VAD 判定开口（宿主亮录音态 UI）
signal chunk(pcm: PackedByteArray)       # 服务端 sink：分片就绪（端侧路径不发，内部直喂插件）
signal local_final(text: String)         # 端侧识别出最终文本
signal committed(pcm: PackedByteArray)   # 说完：端侧路径 pcm 空、服务端路径给整段
signal cancelled()                       # 太短/闭麦，静默丢弃

var should_listen: Callable               # 宿主门禁：该不该开麦
func step(delta) -> void                  # 宿主每帧驱动（宿主自己的 _process 里调）
func level() -> float                     # 供声波条 UI
func is_ready() -> bool                   # 端侧就绪
func close() -> void                      # 关麦 + 断信号（退场）
```

BGM 门控内置：`step` 里按「mic 开 = 静音、开口录音期 = 静音、其余 duck 跟随」统一写一次，两个宿主再也不会漂。

## 风险与护栏

- world.gd 这条链是真机调参、行为被 `test_interaction_fsm`（64 组合）+ `test_voice_vad` + `test_visual_interactions/intro` 锁定的。重构必须**行为等价**：改完这些测试全绿即护栏。
- onboarding 有 `test_onboarding_vad` / `test_onboarding_asr_gate` / `test_onboarding_audio` 护栏。
- 端侧 ASR 真机链路 headless 测不到（无 MaliangAsr 单例），真机验证留老板。

## 抽取激进度（待老板拍板，见决策卡）

- **A 保守（推荐）**：两宿主都接入，但 world 的退避/喊话/造物/打点/logcat 留在宿主当回调；模块只吃机械核 + BGM 门控。口径从此单一真相，bug 结构性消失，world 行为等价靠现有测试兜。
- **B 最小**：只 onboarding 接入，world 暂不动。风险最低但 world 仍是「参照副本」，反向漂移隐患还在。
- **C 激进**：连退避/喊话/造物都并进模块。耦合最高，模块被 world 语义绑架。
