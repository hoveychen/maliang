# tripo_lowpoly — 一句命令生低多边形 3D 模型

用 [Tripo3D](https://platform.tripo3d.ai) 把一句文字描述变成一个低多边形 3D 物品（`.glb`），可选自动绑骨 + 套走路/待机等动画。适合快速造 maliang 场景道具和可动角色。

## 链路

```
文字描述 → 生 flat low-poly 概念图(OpenRouter) → 上传 Tripo → image-to-3D(低模)
          → [绑骨] → [套动画] → 下载 glb + 概念图 + 渲染预览
```

先出一张干净的 flat low-poly **概念图**把风格锁死，再喂 Tripo `image-to-3D`——实测比 `text-to-3D` 直出风格统一得多（直出常烤上写实 AI 贴图，宝箱糊、蘑菇黏土感）。

## 前置

| 依赖 | 说明 |
|---|---|
| `TRIPO_API_KEY` | 必填。platform.tripo3d.ai 注册免费档拿；免费额度 ~600cr（发首个任务后才激活，`balance` 首查是 0 属正常） |
| `OPENROUTER_API_KEY` | 生图必填（`--image` 跳过生图时可省）。取自 `server/.env` |
| ssh `own-api-ko` | 港区默认走首尔出口机生图（港区 IP 直连 Google 图像模型一律 403）。非受限区可 `--exit-host ""` 走本地 |

## 用法

```bash
# 静态物品
TRIPO_API_KEY=tsk_... OPENROUTER_API_KEY=sk-... \
  node server/tools/tripo_lowpoly.mjs "a wooden barrel" --out ./out --name barrel

# 可动角色（绑骨 + 走路动画）
node server/tools/tripo_lowpoly.mjs "a chubby orange kitten" --out ./out --animate walk

# 用现成概念图跳过生图
node server/tools/tripo_lowpoly.mjs --image ./my_concept.png --out ./out --name thing
```

产物：`<name>.glb`（模型）、`<name>.render.webp`（渲染预览）、`<name>.concept.jpg`（概念图，生图时）。

## 选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `--out <dir>` | `./tripo-out` | 输出目录 |
| `--name <slug>` | 从描述推 | 输出文件名前缀 |
| `--face-limit <n>` | `2500` | 低模目标面数（实测精确控面，1000→1183 / 2500→2500） |
| `--image <path>` | — | 用现成概念图，跳过生图 |
| `--exit-host <host>` | `$IMAGE_EXIT_HOST` 或 `own-api-ko` | 港区代理生图出口机；`""` 走本地 |
| `--image-model <id>` | `google/gemini-3.1-flash-lite-image` | 生图模型 |
| `--rig` | 关 | 绑骨（角色/生物才需要，出 Skeleton3D） |
| `--animate <preset>` | — | 套动画预设（`walk`/`run`/`idle`/`jump`…），隐含 `--rig` |
| `--keep-concept` | 关 | 保留概念图 |

## 批量

```bash
for item in "a cartoon tree" "a red mushroom" "a stone rock" "a wooden fence"; do
  node server/tools/tripo_lowpoly.mjs "$item" --out ./assets
done
```

## 成本（实测，$1 = 100 credits）

| 项 | credits | ≈$ |
|---|---|---|
| 静态低模物品 | image-to-3D 30 + 生图 | **~$0.33** |
| 动画角色 | 图30 + 骨25 + 动画10 = 65 + 生图 | **~$0.68** |
| 每多一个动作 | +10 | +$0.10 |

生图走 OpenRouter ~$0.03/张。免费额度用完后 Tripo `$1=100cr`。

## 相关

- 港区代理生图脚本：`fetch_openrouter_images.py`（本工具自动复用）
- API 端点契约 / 选型细节：见 memory `tripo-lowpoly-3d-recipe`
- ⚠️ 本工具只是**资产生成侧**。真把 3D 物品接进 maliang 是 2.5D 纸片人 → 真 3D 的画风 + 平板性能大改，另需评估。
