// SDF blend-shell 公共部分：基本体距离场 + smooth-min 融合 + 顶点吸附。
// 与 scripts/sdf_math.gd 一一对应（形状编号/参数布局/smin/圆角盒系数），两边改必须同步改。
//
// 数据布局（由 SdfProp 每帧喂 uniform，网格顶点存基本体局部坐标、UV2.x 存基本体索引）：
//   prim_pos[i]    = xyz 基本体物件空间位置, w = 形状(0球/1胶囊/2圆头锥/3圆角盒)
//   prim_rot[i]    = 单位四元数
//   prim_params[i] = xyz 尺寸参数, w = 该基本体 blend 上限（细件调小防被吞）
//   prim_color[i]  = rgb 颜色
//
// 顶点吸附：先按当前基本体变换把顶点摆到物件空间（"刚性蒙皮"），
// 再沿融合场梯度迭代投影到等值面——重叠处两张壳收敛到同一张 smin 面，接缝消失。

const int MAX_PRIMS = 24;

uniform int prim_count = 0;
uniform vec4 prim_pos[MAX_PRIMS];
uniform vec4 prim_rot[MAX_PRIMS];
uniform vec4 prim_params[MAX_PRIMS];
uniform vec4 prim_color[MAX_PRIMS];
uniform vec4 prim_curve[MAX_PRIMS]; // 仅 bezier(shape 5) 用：B.xy, C.xy（局部，A 固定在原点）；其余基本体为 0
uniform float blend_k = 0.25;       // 全局融合半径
uniform float color_k = 0.18;       // 颜色软混合宽度
uniform float curvature = 0.0015;   // world-bend 曲率（与 BendMat.CURVATURE 一致）

// 吸附迭代数：每次迭代 = 5 次全基本体场求值（sdf_all + 四面体梯度），是可动物件
// 顶点着色器的成本主轴（真机隐藏 7 个物件 100ms→24.8ms）。桌面 4 保精度，
// 移动端 2 已收敛（SdfProp 按平台设置；描边壳精度无所谓给 1）。
uniform int snap_iters = 4;

const float BOX_ROUND_FRAC = 0.2;
const float TUCK_START = 0.03;  // 顶点静止点埋入联合体超过此深度开始收皮
const float TUCK_FULL = 0.08;   // 埋入到此深度完全收到皮下
const float TUCK_ISO = -0.05;   // 收皮目标等值面（皮下 5cm，藏住不打架）

vec3 quat_rotate(vec4 q, vec3 v) {
	return v + 2.0 * cross(q.xyz, cross(q.xyz, v) + q.w * v);
}

vec3 quat_unrotate(vec4 q, vec3 v) {
	return quat_rotate(vec4(-q.xyz, q.w), v);
}

float sd_round_cone(vec3 p, float r1, float r2, float half_h) {
	float h = 2.0 * half_h;
	float py = p.y + half_h;
	float b = clamp((r1 - r2) / max(h, 1e-6), -0.999, 0.999);
	float a = sqrt(1.0 - b * b);
	vec2 q = vec2(length(p.xz), py);
	float k = dot(q, vec2(-b, a));
	if (k < 0.0) { return length(q) - r1; }
	if (k > a * h) { return length(q - vec2(0.0, h)) - r2; }
	return dot(q, vec2(a, b)) - r1;
}

float sd_round_box(vec3 p, vec3 he) {
	float rr = min(he.x, min(he.y, he.z)) * BOX_ROUND_FRAC;
	vec3 q = abs(p) - he + vec3(rr);
	return length(max(q, vec3(0.0))) + min(max(q.x, max(q.y, q.z)), 0.0) - rr;
}

// 环面：环在 XY 平面、孔轴沿 Z。arc_deg=180 满环，<180 开口 C 环（开口居中在 -Y）。
// 满环用解析式；开口段用 IQ capped-torus（以 +Y 为对称轴的弧）。
float sd_torus(vec3 p, float R, float r, float arc_deg) {
	if (arc_deg >= 179.5) {
		return length(vec2(length(p.xy) - R, p.z)) - r;
	}
	vec2 sc = vec2(sin(radians(arc_deg)), cos(radians(arc_deg)));
	p.x = abs(p.x);
	float k = (sc.y * p.x > sc.x * p.y) ? dot(p.xy, sc) : length(p.xy);
	return sqrt(dot(p, p) + R * R - 2.0 * R * k) - r;
}

// 平面二次贝塞尔到点的距离（IQ 闭式解）。返回 vec2(面内无符号距, 最近参数 t∈[0,1])。
vec2 sd_bezier(vec2 pos, vec2 A, vec2 B, vec2 C) {
	vec2 a = B - A, b = A - 2.0 * B + C, c = a * 2.0, d = A - pos;
	// 退化：控制点共线且 B≈中点时 b≈0（闭式解会除零）→ 退回线段 A→C 距离
	if (dot(b, b) < 1e-8) {
		vec2 ba = C - A, pa = pos - A;
		float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
		return vec2(length(pa - ba * t), t);
	}
	float kk = 1.0 / dot(b, b);
	float kx = kk * dot(a, b);
	float ky = kk * (2.0 * dot(a, a) + dot(d, b)) / 3.0;
	float kz = kk * dot(d, a);
	float res = 0.0, tres = 0.0;
	float pp = ky - kx * kx;
	float p3 = pp * pp * pp;
	float q = kx * (2.0 * kx * kx - 3.0 * ky) + kz;
	float h = q * q + 4.0 * p3;
	if (h >= 0.0) {
		h = sqrt(h);
		vec2 x = (vec2(h, -h) - q) / 2.0;
		vec2 uv = sign(x) * pow(abs(x), vec2(1.0 / 3.0));
		float tt = clamp(uv.x + uv.y - kx, 0.0, 1.0);
		res = dot(d + (c + b * tt) * tt, d + (c + b * tt) * tt);
		tres = tt;
	} else {
		float z = sqrt(-pp);
		float v = acos(q / (pp * z * 2.0)) / 3.0;
		float m = cos(v), n = sin(v) * 1.732050808;
		vec3 t3 = clamp(vec3(m + m, -n - m, n - m) * z - kx, 0.0, 1.0);
		vec2 e0 = d + (c + b * t3.x) * t3.x;
		vec2 e1 = d + (c + b * t3.y) * t3.y;
		float d1 = dot(e0, e0);
		float d2 = dot(e1, e1);
		if (d1 < d2) { res = d1; tres = t3.x; } else { res = d2; tres = t3.y; }
	}
	return vec2(sqrt(res), tres);
}

// bezier 圆管：曲线在 XY 平面(A=原点, B/C 由 prim_curve 给)，圆截面半径 r0→r1 变径。
// fork>0 时在 C 端外侧挖圆口。
float sd_bezier_tube(vec3 lp, vec4 curve, float r0, float r1, float fork) {
	vec2 A = vec2(0.0);
	vec2 B = curve.xy;
	vec2 C = curve.zw;
	vec2 dt = sd_bezier(lp.xy, A, B, C);
	float d = length(vec2(dt.x, lp.z)) - mix(r0, r1, dt.y);
	if (fork > 0.0) {
		vec2 tip = C + normalize(C - B) * fork * 0.9;
		d = max(d, -(length(lp.xy - tip) - fork));
	}
	return d;
}

float sdf_prim(int i, vec3 p) {
	vec3 lp = quat_unrotate(prim_rot[i], p - prim_pos[i].xyz);
	int shape = int(prim_pos[i].w + 0.5);
	vec3 pa = prim_params[i].xyz;
	if (shape == 0) { return length(lp) - pa.x; }
	if (shape == 1) {
		lp.y -= clamp(lp.y, -pa.y, pa.y);
		return length(lp) - pa.x;
	}
	if (shape == 2) { return sd_round_cone(lp, pa.x, pa.y, pa.z); }
	if (shape == 3) { return sd_round_box(lp, pa); }
	if (shape == 4) { return sd_torus(lp, pa.x, pa.y, pa.z); }
	return sd_bezier_tube(lp, prim_curve[i], pa.x, pa.y, pa.z);
}

float smin(float a, float b, float k) {
	if (k <= 1e-6) { return min(a, b); }
	float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
	return mix(b, a, h) - k * h * (1.0 - h);
}

float sdf_all(vec3 p) {
	float d = 1e9;
	for (int i = 0; i < prim_count; i++) {
		d = smin(d, sdf_prim(i, p), min(blend_k, prim_params[i].w));
	}
	return d;
}

vec3 sdf_grad(vec3 p) {
	const float e = 0.01;
	vec3 g = vec3(0.0);
	g += vec3(1.0, -1.0, -1.0) * sdf_all(p + vec3(1.0, -1.0, -1.0) * e);
	g += vec3(-1.0, -1.0, 1.0) * sdf_all(p + vec3(-1.0, -1.0, 1.0) * e);
	g += vec3(-1.0, 1.0, -1.0) * sdf_all(p + vec3(-1.0, 1.0, -1.0) * e);
	g += vec3(1.0, 1.0, 1.0) * sdf_all(p + vec3(1.0, 1.0, 1.0) * e);
	return g / (4.0 * e);
}

// 把静止壳顶点吸附到融合场等值面。iso_offset：主壳 0，描边壳 +描边宽。
// 返回吸附后的物件空间位置；out_normal 给出该点场梯度（未归一化前已归一）。
vec3 sdf_snap(vec3 shell_pos, float iso_offset, out vec3 out_normal) {
	float d0 = sdf_all(shell_pos);
	// 埋没收皮：静止点深埋联合体内的顶点投到皮下，不与真表面打架
	float bury = smoothstep(TUCK_START, TUCK_FULL, -d0);
	float iso = mix(iso_offset, TUCK_ISO, bury);
	vec3 p = shell_pos;
	for (int it = 0; it < snap_iters; it++) {
		float d = sdf_all(p) - iso;
		vec3 g = sdf_grad(p);
		float gl = max(length(g), 1e-5);
		p -= g / gl * d;
	}
	vec3 g_end = sdf_grad(p);
	out_normal = g_end / max(length(g_end), 1e-5);
	return p;
}

// 颜色按各基本体场值贴近程度软混合：越贴近该基本体表面权重越大。
vec3 sdf_color(vec3 p) {
	float d = sdf_all(p);
	vec3 acc = vec3(0.0);
	float wsum = 1e-5;
	for (int i = 0; i < prim_count; i++) {
		float di = sdf_prim(i, p);
		float w = clamp(1.0 - (di - d) / color_k, 0.0, 1.0);
		w *= w;
		acc += prim_color[i].rgb * w;
		wsum += w;
	}
	return acc / wsum;
}

// world-bend：与 shaders/world_bend.gdshader 同一公式。
// SdfProp 约定节点只做 yaw 旋转+平移（无缩放/俯仰），此时世界 y 轴 == 物件 y 轴，
// 世界空间的下压量可以直接加在物件空间 y 上。
vec3 apply_bend(vec3 obj_pos, mat4 model) {
	vec2 wxz = (model * vec4(obj_pos, 1.0)).xz;
	obj_pos.y -= curvature * dot(wxz, wxz);
	return obj_pos;
}
