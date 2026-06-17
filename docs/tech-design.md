# maliang 技术设计文档（MVP）

> 面向幼儿园儿童（不识字，交互全靠视觉+语音）的 Android 平板/手机沙盒游戏。
> 本文档基于 2026-06-17 与 Boss 敲定的技术选型，渲染技术 Demo 已验证落地于 main。

---

## 1. 产品概述

- **用户**：幼儿园儿童，不识字，发音不清。一切交互靠视觉与语音，**界面上不出现需要阅读的文字**。
- **核心循环**：在一个动漫风草原小村庄里，点击有个性的角色 → 进入交互模式 → 用语音跟它说话 / 下达它能做的预设指令 → 角色用语音+动作回应。
- **魔法感来源**：地图中央的「小神仙」能按孩子的口头想法**现场创造**新角色加入世界。

## 2. MVP 范围

**做：**
- 有限但首尾循环的二维世界（数据层平铺环面 1000×1000，渲染层弯曲出小星球观感）。
- HD-2D：3D 场景 + 2D 纸片角色。初始地图＝草原小村庄。
- 角色：个性 / chat history / memory / 外观 / 状态机+AI 脚本，由 LLM + AIGC 实时创建。
- 小神仙默认技能：按玩家想法造新角色。
- 交互：点角色 → 交互模式 → 点一下开始聆听（角色显耳朵图标）→ 说完点发送 → 云 ASR → LLM 抽意图 → 执行/对话 → TTS 回应。
- 预设能力：`move_to`（去某地）、`deliver_message`（去某角色那传话）、`create_character`（仅小神仙）。
- 单机单世界、单设备本地存档 + 后端持久化角色资源。

**不做（MVP 之后）：**
- 多人/联机（worldlet 已有 instanced 设计，留后）。
- 角色对战、复杂经济系统、任务系统。
- 跨设备云同步、账号体系。

## 3. 系统架构

```
┌─────────────── Android 客户端 (Godot 4, GDScript) ───────────────┐
│  渲染: HD-2D (Sprite3D 纸片) + world-bending shader [已实现]       │
│  逻辑: toroidal grid + chunk streaming [已实现]                    │
│  输入: 点角色→交互模式→录音→发送                                    │
│  缓存: 已生成 sprite / 世界状态本地缓存                             │
└────────────────────────┬─────────────────────────────────────────┘
                         │ WebSocket(流式进度/推送) + REST(存取/资源)
┌────────────────────────┴─────────────────────────────────────────┐
│                    后端代理服务 (Node/TypeScript, 自托管 muvee)     │
│  · 任务编排: 造角色 = LLM→生图→抠图→切片→审核→落地                  │
│  · 长任务队列 + 进度推送 (映射 worldlet 的 requestId+progress)      │
│  · 世界状态持久化 (角色 memory / chat history / 位置)              │
│  · ASR/TTS 代理；所有 API key 只在这里，绝不下发 APK               │
└──┬──────────┬──────────┬──────────┬──────────┬────────────────────┘
   │ LLM      │ 生图      │ ASR      │ TTS      │ 内容审核
 Claude    OpenRouter  讯飞       讯飞       文+图双审
 API      (Gemini img)
```

**关键原则：客户端薄（渲染+输入+缓存），复杂度全在后端。** 任何密钥、任何第三方调用、任何审核都只发生在后端。

## 4. 客户端设计（Godot 4 / GDScript）

### 4.1 渲染层（已实现，见 main）
- `scripts/world_grid.gd`：纯静态环面坐标数学（`wrap_pos` / `shortest_delta` / `to_tile`），含单元测试。
- 浮动原点：玩家固定渲染原点，世界相对滚动，逻辑坐标取模 wrap → 跨 1000 边界无跳变。
- `shaders/world_bend.gdshader` + `scripts/bend_mat.gd`：视图空间按水平距离平方下压顶点，弯出小星球地平线。所有世界几何共用。
- 精灵不走 shader，用 CPU 复算弯曲量沿相机上方向落到弯曲地表（`world.gd._place_on_bent_ground`）。
- `scripts/chunk_manager.gd`：玩家周围 11×11 区块对象池，按 wrap 索引确定性皮肤。
- `scripts/paper_character.gd`：HD-2D 纸片角色（Sprite3D，绕 Y 轴朝相机）。

### 4.2 待建客户端模块
- **角色注册表 / 同步**：从后端拉世界状态，按逻辑坐标放置角色，订阅 WebSocket 增量更新。
- **行为执行器**（移植 worldlet `BehaviorExecutor`）：在客户端跑后端下发的行为脚本（move_to/wander/say/face/emote/wait），驱动角色在环面上移动。注意所有移动也走 `wrap_pos`。
- **交互模式 UI**（全图标，无文字阅读）：
  1. 点角色 → 相机聚焦该角色，弹出交互态。
  2. 点「聆听」按钮（或直接点角色）→ 角色头顶显示**耳朵图标**[已实现占位]，开始 `AudioStreamMicrophone` 录音。
  3. 点「发送」按钮 → 停止录音，上传音频到后端。
  4. 等待期：角色显示「思考中」气泡动画。
  5. 收到回应：播放 TTS 音频 + 执行附带的行为脚本 + 角色气泡显示**图标化**情绪。
- **录音**：Godot `AudioStreamMicrophone`；Android 需 `RECORD_AUDIO` 权限 + 首次启动的儿童监护人同意流程。
- **小神仙造角色 UX**：点小神仙 → 说出想要的角色 → 「施法中」动画（掩盖 10–30s 生成延迟）→ 新角色降生动画。

### 4.3 输入与无障碍
- 触屏为主：点角色、点按钮、虚拟摇杆/点地移动（移植 worldlet `virtual_controls`）。
- 所有可点元素配音效与放大反馈；关键提示用语音播报而非文字。

## 5. 后端设计（Node/TypeScript）

### 5.1 通信协议
**WebSocket（实时/长任务）**
- `C→S` `voice_input` `{ world_id, character_id, audio: <opus/wav blob> }`
- `C→S` `create_character_request` `{ world_id, by: "fairy", audio | text_intent }`
- `C→S` `move_intent` `{ world_id, character_id, target_tile }`
- `S→C` `gen_progress` `{ request_id, stage }` （stage: spec/text/moderate_text/image/cutout/moderate_image/persist）
- `S→C` `gen_complete` `{ request_id, character: <Character> }`
- `S→C` `character_response` `{ character_id, tts_url, behavior_script, emotion_icon }`
- `S→C` `world_update` `{ characters_delta }`

**REST（存取/资源）**
- `POST /worlds` 新建世界（含初始小神仙 + 草原村庄）
- `GET /worlds/:id` 拉世界状态
- `PUT /worlds/:id` 存档
- `GET /assets/:hash` 取生成的 sprite（对象存储/CDN）

### 5.2 任务队列与进度
- 造角色是 10–30s 长任务：入队列，按 `request_id` 跟踪，每阶段经 WebSocket 推 `gen_progress`，完成推 `gen_complete`。沿用 worldlet `AIPipeline` 的 requestId+progress 模型。
- 失败重试 1 次（参考 worldlet `MaxRetries=1`），失败时给客户端友好降级（小神仙「这次没成功，再试试？」）。

### 5.3 造角色编排管线
```
玩家语音/意图
  → [1] ASR(讯飞)            : 音频 → 文字
  → [2] LLM 抽意图(Claude)   : 文字 → 角色 spec (name/personality/visual/voice/abilities)
  → [3] 文字审核             : spec 文字过儿童适宜性审核
  → [4] 生图(OpenRouter)     : visual_description → 纯色(绿幕)背景立绘
  → [5] 抠图+切片            : ChromaKey 去绿 + (可选)SpriteSheetSlicer 切帧
  → [6] 图片审核             : 成品图过 NSFW/儿童适宜审核
  → [7] 落地                 : 存角色 + 上传 sprite 到对象存储 + 推 gen_complete
```
- 步骤 2/4 的 prompt 都强约束「Paper-Mario 动漫风、儿童友好、无暴力无恐怖」（移植 worldlet 的 designer prompt 思路）。
- 步骤 3/6 任一不通过 → 不落地，让小神仙礼貌重试或换个说法。

## 6. 角色数据模型

```jsonc
Character {
  "id": "uuid",
  "name": "草莓兔",
  "is_fairy": false,                  // 小神仙标记
  "personality": "1-2 句个性描述",
  "voice_id": "讯飞音色 id",
  "appearance": {
    "visual_description": "生图用描述",
    "sprite_asset": "asset hash",     // 对象存储引用
    "scale": 1.0
  },
  "memory": ["长期事实/玩家告诉过它的事"],   // 跨会话
  "chat_history": [{ "role": "child|npc", "text": "...", "ts": 0 }],
  "state": "idle",                    // 状态机当前态
  "behavior_script": { "commands": [...], "loop": true },
  "position": { "tile_x": 0, "tile_y": 0 },   // 环面坐标
  "abilities": ["move_to", "deliver_message"],// 小神仙额外有 create_character
  "relationships": { "<character_id>": "friend|..." }
}
```

### 6.1 行为脚本（客户端可执行，移植 worldlet）
- 基础命令：`move_to{tile|location}` / `wander{radius,duration}` / `wait{duration}` / `say{text}` / `emote{icon}` / `face{target}`。
- maliang 扩展：`deliver_message{to_character_id, message}`（走到目标角色处把话传到，触发对方 chat）。
- `create_character{spec}`：仅 `is_fairy` 角色可用，触发后端造角色管线。
- 所有移动经 `WorldGrid.wrap_pos`，寻路在平面网格上算。

## 7. 世界状态模型
- `World { id, grid: {1000×1000}, characters: [...], player_position, created_at }`。
- tile 层 MVP 先只区分草地/村庄装饰（地形细节后置）。
- 持久化：后端权威存档（角色 memory/chat_history/位置）；客户端本地缓存只读快照 + 已下载 sprite。

## 8. 语音交互流程（端到端）
```
点角色 → 交互模式 → 点聆听(角色显耳朵) → 录音 → 点发送
  → 上传音频 → 后端 ASR(讯飞) → LLM(Claude) 判断：闲聊？还是预设能力指令？
     · 闲聊 → 生成回应文字(带个性+memory) → 文字审核 → TTS(讯飞) → 推 character_response
     · 指令 → 解析为 behavior_script(move_to/deliver_message/create_character) → 推下发
  → 客户端：播 TTS + 跑行为脚本 + 图标化情绪气泡
  → 更新该角色 memory/chat_history（后端持久化）
```

## 9. 内容安全管线（面向幼儿，强制）
- **文字审核**：角色 spec、对话回应落地前都过审核（Claude 自身约束 + 额外分类判定），不适宜则拦截重试。
- **图片审核**：生成成品图过 NSFW + 儿童适宜性分类，未过不落地。
- **Prompt 约束**：所有生成 prompt 注入儿童友好/无暴力恐怖/动漫风格的 system 约束。
- **未成年人录音合规**：原始音频**不持久化**（ASR 后即弃），首启监护人同意，数据最小化。
- 失败一律降级为「小神仙温和重试」，绝不把不适宜内容呈现给孩子。

## 10. 第三方服务
| 用途 | 服务 | 备注 |
|---|---|---|
| LLM（造角色/意图/对话）| Claude API | 中文对话 + 意图抽取强 |
| 生图 | OpenRouter（`google/gemini-*-image`）| 沿用 worldlet 主路径；纯色背景 + ChromaKey 抠图 |
| ASR + TTS | 讯飞 iFlytek | 中文幼儿识别最强；TTS 多音色 |
| 内容审核 | 文字(LLM 判定) + 图片(分类服务) | 待选型确认图片审核服务 |
| 对象存储 | 待定（muvee dataset / S3 兼容）| 存生成的 sprite |

## 11. 部署
- 自托管 muvee PaaS（muveectl）。后端容器 + 任务队列 + 对象存储。
- 不 push 远端需 Boss 显式授权；APK 不含任何密钥。

## 12. 里程碑
- [x] **M0 渲染技术 Demo**（已合并 main）：平铺环面 + 弯曲渲染 + chunk streaming + HD-2D 角色 + 点击交互。
- [ ] **M1 后端骨架 + 生成闭环**：Node/TS 后端 + WebSocket/REST + 打通 Claude/OpenRouter/讯飞/审核，证明「小神仙造角色」端到端能跑（先文字驱动，再接语音）。
- [ ] **M2 语音交互闭环**：客户端录音 → ASR → LLM 意图 → TTS 回应 → 行为脚本执行；交互模式 UI 完整化。
- [ ] **M3 世界与持久化**：草原村庄初始地图、角色注册同步、本地缓存 + 后端存档、行为执行器移植。
- [ ] **M4 安全与合规**：文字+图片审核接入、录音合规流程、儿童 UX 打磨（全图标/语音播报）。
- [ ] **M5 Android 真机**：导出配置、真机性能/录音权限、包体优化。

## 13. 风险与未决问题
- **幼儿 ASR 准确率**：最高风险。M2 要尽早用真实幼儿语音测讯飞，必要时强化 LLM 意图容错或加点选回退。
- **生图角色一致性**：同一角色多姿态/表情的一致性；MVP 先单立绘，后续探索参考图/sprite sheet。
- **生成延迟体验**：10–30s 靠「施法中」动画掩盖，需做得足够有趣不让孩子失去耐心。
- **图片审核服务选型**：待定。
- **对象存储选型**：muvee dataset vs S3 兼容，待定。
- **真机性能**：树节点对象池、阴影方案（假地面阴影）在上真机前补。
```
