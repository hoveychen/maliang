shader_type spatial;
render_mode cull_back, specular_disabled;
// SDF blend-shell 主 pass：顶点吸附到 smooth-min 融合面（接缝消失），
// 法线取场梯度（光照跨关节连续），颜色按场值贴近度软混合（拼接处自带渐变）。
// 依然是普通网格光栅化——逐顶点开销、无 raymarch、无蒙皮，mobile 渲染器友好。
// toon 三段光 + 菲涅尔 rim，配 sdf_outline.gdshader 作 next_pass 描边。

#include "res://shaders/sdf_field.gdshaderinc"

// —— 纸艺化（画质页样式键 papercraft，SdfProp.set_papercraft 接线）——
// 与 world_bend.gdshader 同一套语法子集：折面化法线+折痕白描+纸纹+卡纸色调。
// 三段 toon 光已是本 shader 固有（见 light()），无需 bands 旋钮。默认全 0 = 观感不变。
uniform float paper_facet : hint_range(0.0, 1.0) = 0.0;
uniform float paper_edge : hint_range(0.0, 1.0) = 0.0;
uniform float paper_grain : hint_range(0.0, 1.0) = 0.0;
uniform float paper_tone : hint_range(0.0, 1.0) = 0.0;

varying vec3 v_col;
varying vec3 v_world;  // 纸纹取弯曲前世界坐标（视空间噪声随相机游动，弯曲后随焦点游动）

float paper_hash(vec3 q) {
	return fract(sin(dot(q, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float paper_noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n0 = mix(paper_hash(i), paper_hash(i + vec3(1.0, 0.0, 0.0)), f.x);
	float n1 = mix(paper_hash(i + vec3(0.0, 1.0, 0.0)), paper_hash(i + vec3(1.0, 1.0, 0.0)), f.x);
	float n2 = mix(paper_hash(i + vec3(0.0, 0.0, 1.0)), paper_hash(i + vec3(1.0, 0.0, 1.0)), f.x);
	float n3 = mix(paper_hash(i + vec3(0.0, 1.0, 1.0)), paper_hash(i + vec3(1.0, 1.0, 1.0)), f.x);
	return mix(mix(n0, n1, f.y), mix(n2, n3, f.y), f.z);
}

void vertex() {
	int pi = int(UV2.x + 0.5);
	// 刚性蒙皮：基本体局部顶点 → 当前姿态的物件空间
	vec3 shell = quat_rotate(prim_rot[pi], VERTEX) + prim_pos[pi].xyz;
	vec3 n;
	vec3 p = sdf_snap(shell, 0.0, n);
	v_col = sdf_color(p);
	v_world = (MODEL_MATRIX * vec4(p, 1.0)).xyz;
	VERTEX = apply_bend(p, MODEL_MATRIX);
	NORMAL = n;
}

void fragment() {
	ALBEDO = v_col;
	if (paper_facet > 0.001) {
		// 屏幕导数叉积 = 壳网格面片法线：平滑融合面变硬折面（与 world_bend 同款）
		vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		fn = dot(fn, VERTEX) > 0.0 ? -fn : fn;
		NORMAL = normalize(mix(NORMAL, fn, paper_facet));
	}
	if (paper_tone > 0.001) {
		float plum = dot(ALBEDO, vec3(0.299, 0.587, 0.114));
		ALBEDO = mix(ALBEDO, mix(ALBEDO, vec3(plum), 0.25) * 1.06 + 0.02, paper_tone);
	}
	if (paper_grain > 0.001) {
		float g = 0.65 * paper_noise(v_world * 2.2) + 0.35 * paper_noise(v_world * 9.0);
		ALBEDO *= mix(1.0, 0.78 + 0.44 * g, paper_grain);
	}
	if (paper_edge > 0.001) {
		float crease = clamp((length(fwidth(NORMAL)) - 0.10) * 3.0, 0.0, 1.0);
		ALBEDO = mix(ALBEDO, vec3(0.96, 0.94, 0.90), crease * paper_edge);
	}
	ROUGHNESS = 1.0;
	// 菲涅尔 rim：暗侧一圈冷光，纸玩具质感
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	EMISSION = v_col * rim * 0.12;
}

void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	// 三段 toon：亮面 / 中间调 / 暗面，边界略作平滑抗锯齿
	float band = smoothstep(-0.08, 0.02, ndl) * 0.45 + smoothstep(0.25, 0.38, ndl) * 0.55;
	DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR / PI * (0.3 + band) * ATTENUATION;
}
