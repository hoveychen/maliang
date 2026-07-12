# 游戏内造物新增 SDF 弯曲词汇设计

给「造物品」管线(小朋友说 → LLM 出 JSON → 融合成圆润 mesh)新增两种基本体,让 LLM
能造出**带环**、**带弯管**的物件(轮子/呼啦圈/甜甜圈/把手/光环、花茎/彩带/尾巴/拱)。

来源:SDF 雕刻 skill(`~/.claude/skills/sdf-sculpt/reference/curved-primitives.gdshader`)里
实证跑通的 `sd_capped_torus` 与 `sd_bezier` 弯管词汇。skill 里另一批 2D 贴纸拟合技法
(taper 渐变/偏移阴影/三层贴纸壳/扇贝 lobe)是「把一张平面贴纸用 raymarching 逐像素拟合」
的手法,游戏是真 3D 融合 mesh、无 2D 目标图,**不适用**,不移植。

## 现有链路(5 处必须同步)

1. 运行时 shader `shaders/sdf_field.gdshaderinc` —— 基本体距离场 + smin 融合 + 顶点吸附(GPU)
2. CPU 镜像 `scripts/sdf_math.gd` —— 同一距离场(供单测/包围盒/静态烘焙的 CPU marching)
3. 客户端 parser `scripts/sdf_spec.gd` —— JSON → Prim
4. 服务端校验 `server/src/sdf_prop.ts` —— LLM 产物校验/clamp
5. LLM 提示词 `SDF_PROP_SYSTEM`(`server/src/adapters/openrouter_llm.ts`)

## 核心洞见:两种新形状都是「沿中心线扫掠变径圆管」

- **torus** 中心线 = 局部 XY 平面上一段圆弧(半径 R);截面圆半径 = r(常量)。
- **bezier** 中心线 = 局部 XY 平面上一条二次贝塞尔曲线 A→B→C;截面圆半径沿曲线线性变径 r0→r1。

故网格壳(mesh_builder)用**同一个扫掠管生成器**:给定中心线折线 + 每点半径 → 生成一根圆管
壳网格。torus/bezier 各自算出中心线折线即可,不必各写一套壳。

## 形状编号与参数布局

现有:`0 球 / 1 胶囊 / 2 圆头锥 / 3 圆角盒`。新增:

### SHAPE_TORUS = 4(环 / 甜甜圈 / 轮圈 / 光环 / 把手)

- 平面:环在**局部 XY 平面**,孔轴 = 局部 **Z**。默认正面朝 +Z(像舷窗/光环正对镜头);
  `rot:[90,0,0]` 放平成地上的呼啦圈。
- `params = (R_major, r_minor, arc_deg)`
  - `R_major` 大半径(环心到管心)
  - `r_minor` 管(截面)半径
  - `arc_deg` 弧半角,∈[1,180]。**180 = 满环闭合**;<180 = 开口 C 环(把手),
    开口对称居中在 **-Y** 侧(用 rot 把开口转向想要的方向)。
- 不需要 `prim_curve`(中心线是解析圆弧)。
- CPU/GPU 距离场:满环用 `length(vec2(length(p.xy)-R, p.z)) - r`;开口用 capped-torus 公式
  (`p.x=abs(p.x)`,以 +Y 轴为对称的弧,见 skill sd_capped_torus)。

### SHAPE_BEZIER = 5(弯管:花茎 / 彩带 / 尾巴 / 拱 / 钩)

- 平面:曲线在**局部 XY 平面**,圆截面(半径沿曲线变径),厚度靠圆截面在 Z 方向自然存在。
- 控制点:`A = 基本体局部原点 (0,0)`(即 `pos` 落在 A 处);`B`、`C` **相对局部**,存进新
  uniform `prim_curve[i] = (B.x, B.y, C.x, C.y)`。**只有 bezier 用这条 uniform**(torus/其余
  基本体该项为 0,不参与)。
- `params = (r0, r1, fork)`
  - `r0` 起点(A,t=0)管半径;`r1` 终点(C,t=1)管半径,线性变径
  - `fork` 可选:>0 时在 C 端外侧挖一个半径 fork 的圆口(分叉/开口尾)。缺省 0=无。
- CPU 侧 `Prim` 加字段 `curve: Vector4`(B.xy, C.xy,局部);GPU 侧加 `prim_curve` uniform 数组。
- 距离场:`vec2 dt = sd_bezier(p.xy, A, B, C)`(dt.x=面内距, dt.y=最近参数 t);
  `d = length(vec2(dt.x, p.z)) - mix(r0, r1, dt.y)`;fork 时 `d = max(d, -(dist_to_tip - fork))`,
  tip = `C + normalize(C-B)*fork*0.9`(挖在 C 端**外侧**,不是 C 处——否则在管中段打洞)。

## uniform 布局变更(shader)

现有每基本体 4 条 vec4:`prim_pos(xyz+shape) / prim_rot(quat) / prim_params(xyz+blend) / prim_color(rgb)`。
**新增 1 条**:`prim_curve[MAX_PRIMS]`(vec4,仅 bezier 用,存 B.xy/C.xy)。
`sdf_prop.gd push_uniforms` 每帧多传一个 `PackedVector4Array`(其余基本体填 0)。

## MAX_PRIMS 预算

torus / bezier 各计 1 个基本体,与球/盒同。上限 24 不变。

## 校验/clamp 口径(与现有一致:结构错拒收、数值越界 clamp)

- torus:`R_major` (0.02,2.5)、`r_minor` (0.02,1.5)、`arc_deg` (1,180) 默认 180
- bezier:`b`/`c` 二维点各分量 (-4,4)、`r0`/`r1` (0.02,1.5)、`fork` (0,1) 默认 0
- 体型档整体 scale 一并乘几何量(含 curve 的 B/C、torus R/r)。
