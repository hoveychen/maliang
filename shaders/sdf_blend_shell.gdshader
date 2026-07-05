shader_type spatial;
render_mode cull_back, specular_disabled;
// SDF blend-shell 主 pass：顶点吸附到 smooth-min 融合面（接缝消失），
// 法线取场梯度（光照跨关节连续），颜色按场值贴近度软混合（拼接处自带渐变）。
// 依然是普通网格光栅化——逐顶点开销、无 raymarch、无蒙皮，mobile 渲染器友好。
// toon 三段光 + 菲涅尔 rim，配 sdf_outline.gdshader 作 next_pass 描边。

#include "res://shaders/sdf_field.gdshaderinc"

varying vec3 v_col;

void vertex() {
	int pi = int(UV2.x + 0.5);
	// 刚性蒙皮：基本体局部顶点 → 当前姿态的物件空间
	vec3 shell = quat_rotate(prim_rot[pi], VERTEX) + prim_pos[pi].xyz;
	vec3 n;
	vec3 p = sdf_snap(shell, 0.0, n);
	v_col = sdf_color(p);
	VERTEX = apply_bend(p, MODEL_MATRIX);
	NORMAL = n;
}

void fragment() {
	ALBEDO = v_col;
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
