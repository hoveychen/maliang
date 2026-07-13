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

| 资产 | 用途 | 来源 |
|---|---|---|
| `phone3d_front_shell` | A 外面纸壳(屏幕区由 viewport quad 覆盖) | 实拍纸纹裁切 |
| `phone3d_back_shell` | B 外面纸壳+简笔三摄岛(ImageMagick 矢量描) | 实拍纸纹+程序描 |
| `phone3d_spread_bg` | 跨页内页底(中缝折痕渐变) | 实拍纸纹+程序合成 |
| `phone3d_paper` | 正面视口屏幕底纸纹 | 实拍纸纹 |
| `phone3d_island` | 灵动岛石墨药丸贴片(悬浮正面视口顶部中央) | AIGC pencil 模式 |
| `phone3d_digit_0..9/colon` | 铅笔手写数字贴片(状态栏时钟逐字拼) | AIGC pencil 模式 |
| app 图标 | 复用现有 `app_flowers/app_items/app_settings` 贴纸 | 既有资产 |

落地备注(2026-07-11 老板两轮返工拍板):**全部贴图不用 AIGC**。
第一轮:AIGC 合成的"纸的照片"带木桌残影/光照不均/边框错位,全部废弃。
第二轮:微皱纸纹看着像牛皮纸/皱纹纸——手工该用**硬卡纸**,换成 ambientCG Paper001
光滑白卡纸底色(CC0,见 assets/ui/PHONE3D_PAPER_SOURCE.txt)。AIGC 铅笔数字/灵动岛
贴片也一并退役,改 OFL 手写字体(Patrick Hand)时钟 + 矢量药丸灵动岛。
(生成器的 pencil 模式与两段式 --emit-jobs → 首尔机 → --raw-dir 管线保留备用。)

## "一眼是纸做的"技术清单(参考 Paper Mario: The Origami King 调研)

Origami King 的纸感来源:开发组用真纸做实物 mock-up 对照;白色切边/白描边把"剪出来的
纸片"写在剪影上;纸面是哑光平涂+柔和光照渐变(不是重纹理);"运动中的纸"(crumpled
paper in motion)靠动画卖质感。对应落地:

1. **白色纸芯切边**:面板侧面(BoxMesh 边)用比贴图面更亮的纯白,厚度加到 PANEL_T=0.032
   ——翻转/展开时最抢眼的"纸做的"信号。
2. **哑光卡纸面**:光滑细牙白卡纸 + softlight 对角受光渐变烘进贴图(unshaded 材质下
   模拟纸面接光),四周一圈极淡刀切边线。
3. **持机微摆**:开机后整机 x/z 轴 sine 微旋(±0.7°/±0.5°),纸片"活着"的 stop-motion 感。
4. **翻转 overshoot**:TRANS_BACK 弹性,纸片翻面带一点回弹。
5. **中缝折痕**:跨页中缝烘柔和 V 型阴影渐变(对折的物理痕迹)。

屏幕区几何由代码常量定义(正面壳按固定屏占比设计),**不再用旧的"从壳贴图自动检测屏区"逻辑**。

## 2026-07-13 观感重做(paper-phone-craft,照 onboarding 故事书四支柱)

老板评首版"做得挺粗糙",按故事书成功配方(真实光照/落地感/构造细节/构图)重做:

1. **shaded 哑光卡纸替代 unshaded**。当年选 unshaded 是为了在世界场景光下保亮度稳定
   (太阳方向随相机环绕相对变化)。新解法是**渲染层隔离**:全部 mesh 挪到
   `PaperPhone.RENDER_LAYER`(层 11,全仓库唯一用 .layers 处),世界太阳
   `light_cull_mask` 剔除该层,`attach_light_rig()` 在相机下挂一盏只照该层的
   暖平行光(故事书同参)——灯随相机走,相对光向恒定。实测相机 yaw 扫描
   0/90/180/270° 亮度波动 0.1%,与 unshaded 同级(tools/shoot_phone.gd yawsweep)。
   环境光无方向性天然稳定,保留补底。
2. **圆角芯板 + die-cut 贴图**。BoxMesh 直角芯会从壳贴图圆角后露白角;换成
   SurfaceTool 圆角矩形棱柱(CORNER_R 与贴图圆角同参),壳/跨页贴图烘上圆角
   alpha 镂空(magick roundrectangle),跨页视口开 transparent_bg——三态剪影
   全是圆角剪纸。芯板侧壁=暖白纸芯切边(EDGE_COLOR),吃光后自带一圈明暗。
3. **悬浮软影**。持机物没有桌面,"实体卡"的存在感靠机身后下方一片软影:
   超椭圆贴图、剪影内实心+轮廓外**窄**衰减带(SHADOW_CORE=0.78;书的 0.62 宽衰减
   用在这里会糊成环境渐变,实测)。两个透视坑:深度拉远影子会缩小+滑向灭点
   (藏到机身后面全灭,实测 -0.5 局部深度不可见,收到 -0.10);持机位在画面右侧,
   x 偏移里要含 ~0.045 的灭点漂移补偿,影子才真的落在右下。宽度随折叠进度加宽
   (_apply_pose 里 scale.x = 1+spread_frac)。

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
