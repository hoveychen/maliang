# 资产署名清单 / Asset Credits

马良小世界（maliang）用到的第三方美术/音频资产汇总。本项目仓库为 **公开仓库**，
故只采用许可允许再分发的资产：**CC0**（无需署名）与 **CC-BY**（需署名，见下）。
不采用带「禁止再分发 / 禁商用 / 传染性 SA」条款的资产。

各资产包的具体来源、选用清单与许可原文见对应目录下的 `SOURCES.txt` / `LICENSE.txt`。

---

## 需署名 · CC-BY（Attribution required）

CC-BY 许可要求在作品中保留可见署名。游戏内署名见主菜单底部常驻的两行小字
（`scripts/menu.gd` 的 `_setup_credits`）；完整信息见本文件。

### 音乐 Music — CC BY 4.0
- **Kevin MacLeod** (incompetech.com) — *Carefree* / *Cheery Monday* / *Happy Boy End Theme*
  — CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
  详见 `assets/audio/bgm/LICENSE.txt`。

### 美术 3D 模型 — CC BY 3.0（中国古代主题，world-themes P6）
poly.pizza 匿名下载的东方古建散件（见 `assets/ancient_china/SOURCES.txt`）：

| 物品 | 模型 | 作者 | 许可 | 来源 |
|---|---|---|---|---|
| 宝塔 | Pagoda | **Poly by Google** | CC BY 3.0 | https://poly.pizza/m/d1M5ncMBUDi |
| 牌坊 | Japanese Torii | **Jacques Fourie** | CC BY 3.0 | https://poly.pizza/m/cXyQGUwmlA5 |
| 神龛 | Shrine | **Aidan K McLaughlin** | CC BY 3.0 | https://poly.pizza/m/a68qNnAC4m- |

CC BY 3.0 许可全文：https://creativecommons.org/licenses/by/3.0/

---

## 无需署名 · CC0（Public Domain，署名从简，此处列出以示尊重）

以下资产为 CC0（Creative Commons Zero，公共领域），可自由使用、无需署名。
本项目仍列出作者以示尊重。各包选用清单见对应 `SOURCES.txt`。

### KayKit — 作者 Kay Lousberg（https://kaylousberg.itch.io）
- **Medieval Hexagon Pack** — 基础村庄民居 + 中世纪小镇/王国 + 罗马近似（复用）。
  `assets/kaykit/hexagon`、`assets/medieval/hexagon`、`assets/packs/roman`。
- **Medieval Builder Pack** — 中世纪王国城防 + 罗马近似（复用）。`assets/medieval/builder`。
- **Forest Nature Pack** — 村庄岩石/草丛散布。`assets/kaykit/forest`。
- **Shrine（古亭，中国古代主题用）** — CC0，poly.pizza/m/tFxdxO5clk。`assets/ancient_china/shrine_a.glb`。

### Kenney — 作者 Kenney（https://kenney.nl，全 CC0）
- **Furniture Kit** — 玩具房间 / 厨房 / 医院（拼装）主题。`assets/furniture`、`assets/hospital`。
- **City Kit (Commercial)** — 现代城市主题。`assets/city`。
- **Holiday Kit** — 冰雪世界主题。`assets/winter`。
- **Space Kit** — 未来机器人主题的科幻环境物。`assets/scifi/props`。

### Quaternius — 作者 Quaternius（https://quaternius.com、https://poly.pizza/u/Quaternius，全 CC0）
- **Sci-Fi Robots** — 未来机器人主题的机器人/机甲。`assets/scifi/robots`。
- **Animated Fish** — 海底主题的海洋生物。`assets/underwater`。

### Poly Haven — 主题地形纹理源（themed-terrain，全 CC0 1.0）
主题地形 tile 贴图由以下 CC0 光扫纹理经 `tools/watercolorize.py` 程序化水彩风格化而来
（源纹理不入库，仅记录出处；风格化产物入 `assets/textures/terrain/`）。

| 用途 | Poly Haven slug | 链接 |
|---|---|---|
| 沙 sand | `coast_sand_02` | https://polyhaven.com/a/coast_sand_02 |
| 雪 snow | `snow_03` | https://polyhaven.com/a/snow_03 |
| 珊瑚/礁岩 coral/reef | `coral_ground_02` | https://polyhaven.com/a/coral_ground_02 |
| 白瓷砖 tile | `long_white_tiles` | https://polyhaven.com/a/long_white_tiles |
| 粗沙 coarse_sand（海底 P2）| `coral_gravel` | https://polyhaven.com/a/coral_gravel |
| 珊瑚砂 coral_sand（海底 P2）| `coral_mud_01` | https://polyhaven.com/a/coral_mud_01 |
| 海草地 seagrass（海底 P2）| `aerial_grass_rock` | https://polyhaven.com/a/aerial_grass_rock |
| 深水床 deep_bed（海底 P2）| `brown_mud_leaves_01` | https://polyhaven.com/a/brown_mud_leaves_01 |
| 压实雪 packed_snow（冰雪 P3）| `snow_03` | https://polyhaven.com/a/snow_03 |
| 冰面 ice（冰雪 P3）| `snow_02` | https://polyhaven.com/a/snow_02 |
| 雪泥 slush（冰雪 P3）| `snow_03` | https://polyhaven.com/a/snow_03 |
| 裸岩积雪 rock_snow（冰雪 P3）| `rocks_ground_04` | https://polyhaven.com/a/rocks_ground_04 |
| 干裂土 cracked_earth（侏罗 P3）| `brown_mud_dry` | https://polyhaven.com/a/brown_mud_dry |
| 火山岩 volcanic（侏罗 P3）| `burned_ground_01` | https://polyhaven.com/a/burned_ground_01 |
| 泥沼 mud_bog（侏罗 P3）| `brown_mud_02` | https://polyhaven.com/a/brown_mud_02 |
| 蕨类草地 fern（侏罗 P3）| `forrest_ground_03` | https://polyhaven.com/a/forrest_ground_03 |
| 碎石 rubble（侏罗/罗马 P3）| `bicolour_gravel` | https://polyhaven.com/a/bicolour_gravel |

> P1-P3 逐主题铺开时，新增的每个 Poly Haven / ambientCG 源都追加到本表。

---

## 弃用的资产（许可不兼容公开仓库，留档备查）

- **Atomic Realm — Hospital Assets**（https://atomicrealm.itch.io/hospital-assets）：自定义许可，
  禁止 repackage/resell/**redistribute**（无论是否修改）。本仓库 PUBLIC，提交=公开再分发，冲突。
  医院主题改用 Kenney Furniture Kit（CC0）拼装。
- **CS Studio — Low Poly Chinese Style Building Set 1**（https://cs-studio.itch.io/cs-building-set1）：
  「You may not redistribute it」（禁再分发）+ Unity Package 格式 + 仅 5 模型。同样冲突。
  中国古代主题改用 poly.pizza 上 CC-BY/CC0 散件拼凑。
