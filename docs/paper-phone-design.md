# 3D 纸糊双折叠手机(paper-phone)设计

老板拍板(2026-07-11):**对开跨页**形态 + **三个 app 趁机纸糊风重设计** + **白卡纸+铅笔蜡笔**质感。

## 目标

把现有 2D `CanvasLayer` 手机(全部耦合在 `world.gd`)重造成一个真 3D 的纸糊手机模型:

- 外观仿 iPhone 17 Pro Max 轮廓(圆角直板、灵动岛、左上三摄岛),但材质是幼儿园手工课的白卡纸——铅笔手绘轮廓、蜡笔涂色、贴纸图标、毛糙纸边。
- **对开(bi-fold)结构**:像贺卡一样一道折痕两块面板。
  - **合拢态(默认)** = 完整手机正面:状态栏是手写铅笔数字时钟、主屏是贴纸 app 图标网格。
  - **点开 app** → 整机翻转 180° 同时沿铰链展开 → 背面(原先相对而合的两个内页)变成 **双倍宽跨页**,承载该 app 的完整界面。多内容界面(集邮册/物品/设置)因此有 2× 空间。
- 贴图全部走现有 `server/tools/gen_ui_assets.mjs` AIGC 管线生成。

## 几何与面

一张对折的"纸",两块面板(panel),每块 4 个可见面之二:

| 面 | 内容 | 何时可见 |
|---|---|---|
| A 外面 | 手机正面(屏幕+灵动岛+贴纸图标) | 合拢态朝向相机 |
| B 外面 | 手机背面(铅笔画三摄岛、装饰贴纸) | 合拢态背对相机/翻转动画中 |
| A 内面 | 跨页左半 | 展开态 |
| B 内面 | 跨页右半 | 展开态 |

- 每块面板 = 薄 `BoxMesh`(纸板厚度,侧面用纸边贴图) + 前后两片 `QuadMesh` 贴面(偏移 ε 防 z-fighting)。
- 面板长宽比 ≈ iPhone 17 Pro Max(高:宽 ≈ 2.16:1)。
- 铰链在面板左缘(A)/右缘(B),折叠角 0°(合拢,B 叠在 A 背后) → 180°(摊平成跨页)。

## 状态机

```
STOWED(隐藏) ──掏出──▶ FRONT(合拢,正面朝相机)
FRONT ──点 app 图标──▶ FLIPPING(翻转+展开 tween)──▶ SPREAD(跨页展示 app)
SPREAD ──返回/点手机外──▶ FRONT(反向动画) 或直接收起
FRONT ──点手机外/再点入口──▶ STOWED
```

- 动画:`Tween` 驱动整机 yaw(0→180°)与铰链角(0→180°)并行,~0.45s,带轻微纸张弹性(overshoot)。
- 收起/掏出:从屏幕下方升起 + 微旋转,复用现有开合音效挂点。

## 渲染与挂载

- `PaperPhone extends Node3D`,**挂为 Camera3D 子节点**,固定本地变换(相机前 ~0.55m,居右下),不受 world-bend 影响(材质不用 bend shader,`shaded=false` 或固定环境光,保证纸面亮度稳定)。
- 屏幕内容用 **SubViewport + ViewportTexture**(全仓库首例):
  - `SubViewport front`(约 720×1560):状态栏+贴纸图标网格+桌面 widget,贴在 A 外面的屏幕区 quad。
  - `SubViewport spread`(约 1440×1560):当前 app 界面,A 内面/B 内面各采样左右半 UV。
  - `render_target_update_mode`:打开时 `UPDATE_ALWAYS`,STOWED 时 `DISABLED`;老平板若压力大再降 viewport 分辨率(P6 调参)。
- 现有近身相机运镜(`_enter_phone_cam`)保留:打开手机仍推近玩家,3D 手机悬在画面右侧。

## 输入

不加物理碰撞体。复用现有全屏遮罩 `_phone_scrim` 接收点击:

1. 遮罩 `gui_input` 里 `camera.project_ray_origin/normal` 出射线;
2. 与各可见面板面(已知 Transform3D 的矩形平面)做解析求交,得命中面 + 面内 UV;
3. UV → viewport 像素坐标,构造 `InputEventMouseButton/Motion` `push_input` 进对应 SubViewport——现有 Control 按钮/滚动逻辑原样工作;
4. 未命中任何面 → 维持现状语义(收起手机)。

## AIGC 资产清单(P4)

走 `gen_ui_assets.mjs`,新增清单项(画风统一"白卡纸+铅笔线稿+蜡笔涂色+贴纸",**prompt 禁写 iPhone/Apple 等 IP 名**,用外观描述:"rounded-corner smartphone, pill-shaped island cutout, triple camera rings in rounded square island"):

| 资产 | 用途 |
|---|---|
| `phone3d_front_shell` | A 外面:纸质机身正面框(铅笔 bezel),屏幕区由 viewport quad 覆盖 |
| `phone3d_back_shell` | B 外面:纸质背面(铅笔三摄岛、蜡笔贴纸;圆角外程序白化) |
| `phone3d_spread_bg` | 跨页内页底(蓝红蜡笔双页框+装订线,裁掉木桌边) |
| `phone3d_island` | 灵动岛石墨药丸贴片(悬浮正面视口顶部中央) |
| `phone3d_digit_0..9/colon` | 铅笔手写数字贴片(状态栏时钟逐字拼,Label 隐藏作测试锚点) |
| app 图标 | 复用现有 `app_flowers/app_items/app_settings` 贴纸 |

落地备注:面板侧面纸边不用贴图(米白纯色已够);数字/灵动岛走生成器新增的
`pencil` 模式(白纸生成+亮度键抠,绿幕会吃掉铅笔灰细线);港区 403 时生成走
两段式 `--emit-jobs` → 首尔机 `fetch_openrouter_images.py` → `--raw-dir`。

屏幕区几何由代码常量定义(正面壳按固定屏占比设计),**不再用旧的"从壳贴图自动检测屏区"逻辑**。

## app 重设计(P5,跨页 2× 空间)

- **集邮册**:真·册子跨页——左页 9 朵小红花大格,右页盖章进度(手绘邮票感)+累计数;格子从挤在竖屏 3×3 变成大格。
- **物品**:货架跨页,一屏 6-8 列贴纸物件,份数用手写角标;点击摆放语义不变(摆放后收手机)。
- **设置**:左页"我的形象"(重捏/换形象大按钮),右页画质旋钮组(手绘滑杆),不再滚动。
- 逻辑(钱包数据、bag 权威计数、GraphicsSettings)全部不动,只换界面层。

## 代码重构

手机相关 ~700 行从 `world.gd` 抽出:

- `scripts/paper_phone.gd` — 3D 模型/状态机/动画/射线命中(纯 3D 载体,不懂业务)。
- `scripts/phone_ui.gd` — 两块 SubViewport 内的 Control 树(主屏+三 app 界面),向 world 暴露信号(open_app/place_item/reroll…)。
- `world.gd` 保留:入口按钮、相机运镜、业务回调(钱包刷新/摆物品/换形象)。

## 验收标准(可验证)

1. `scripts/test-headless.sh` 全绿(含现有 `test_phone_menu` 语义迁移后的新版)。
2. 新增 headless 测试:状态机转换、面 UV 命中数学、输入转发(合成点击→SubViewport 内按钮 pressed)、三 app 导航与数据刷新。
3. 视觉截图测试:FRONT 正面与 SPREAD 跨页各出一张截图,人工核查纸糊观感。
4. 桌面跑起来:点入口→正面→点集邮→翻转展开→数据正确→点外面收起,全链路无报错。
5. 真机(平板)手感与帧率验证留老板。
