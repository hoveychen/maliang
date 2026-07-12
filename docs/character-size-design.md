# 角色体型：size → scale 真变高矮

## 背景（现状事实）

角色世界高度当前是**硬约束**的：`_spawn_server_character`（`scripts/world.gd`）把每个村民静态/动画立绘一律归一化到 **6.0** 世界单位（仙子 `FAIRY_HEIGHT=1.5`、占位 `PLACEHOLDER_HEIGHT=3.2`），机制是 `pixel_size = 目标高度 / 贴图高`。立绘原始像素尺寸完全不参与，唯一随立绘走的是**宽高比（胖瘦）**。

数据模型里有 `CharacterSpec.scale` / `Character.appearance.scale` 字段，但**恒为 `1.0`**（`mock.ts` / `openrouter_llm.ts` 里 designCharacter 硬编码），且客户端从不读取——是死字段。

造角色时收集的 `size` 属性（`small`/`medium`/`big`，见 `creation_options.ts`）当前只喂给生图 prompt 画「瘦/正常/胖」的剪影宽度，从不转成世界高度。

## 目标

让造角色时选的「大小」真正改变角色在世界里的**显示高度**：大恐龙比小兔子高。

## 决策（老板拍板）

- **幅度：明显档** —— `small→0.7×(4.2)` / `medium→1.0×(6.0)` / `big→1.4×(8.4)`。
- **范围：引导式 + 自由文本都吃** —— 图标选项走结构化 size；自由文本让 LLM 从描述判断体型。
- **碰撞：无物理碰撞体**（角色是 `MeshInstance3D` 公告板，玩家直接穿过，纸片风设定）。改为**交互手感半径按体型缩放**：`APPROACH_ARRIVE`、`NOTICE_RADIUS` 按目标 scale 缩放。地面阴影半径 `_blob_radius` 本就 = 视觉宽度×pixel_size，自动跟随，白送。
- **存量角色**：`appearance.scale` 缺失/为 1.0 → 继续走 6.0，不跳变。仙子/占位高度不动。

## 权威映射（服务端）

统一放在 `server/src/creation_options.ts`（size id 定义处）：

```ts
export type CreatureSize = 'small' | 'medium' | 'big';
export const SIZE_TO_SCALE: Record<CreatureSize, number> = { small: 0.7, medium: 1.0, big: 1.4 };
// 容错：接受英文枚举 & 中文标签(小/中/大)，非法/缺失 → 1.0
export function sizeToScale(size: string | null | undefined): number;
```

## 数据流

到 `designCharacter(intentText)` 时一切已是文本（spec 的每个字段本就由 LLM 从 desc 解析）。所以 size 也走同一机制：

1. **引导式**：`describeCreationAttrs` 已把 size 以中文嵌进 desc（`一只红大的猫…`）→ LLM designCharacter 从 desc 判断体型。
2. **自由文本**：LLM 直接从「一只很小的猫」判断。
3. `designCharacter` 输出 `size` → `scale = sizeToScale(size)` 写入 `CharacterSpec.scale` → `buildCharacter` 存进 `appearance.scale`。
   - mock：`inferSizeFromText(intentText)` 正则（大/巨→big，小/迷你→small，else medium）确定性产出，供单测。
   - openrouter：JSON schema 增 `size` 字段 + 指令，`sizeToScale(raw.size)`。

## 客户端消费（`scripts/world.gd`）

`_spawn_server_character`：村民目标高度 `6.0` → `6.0 * scale`（静态 + 动画两路），`scale = float(char.appearance.scale ?? 1.0)`。仙子/占位不变。

交互半径按目标 scale 缩放：走向大角色更早停（`APPROACH_ARRIVE * scale`）、大角色更早注意到玩家（`NOTICE_RADIUS * scale`）。

需确认 `appearance.scale` 已随 `scene_entered`/`character_spawned`/`bootstrap` 下发（appearance 整体序列化，应已带；P2 校验）。
