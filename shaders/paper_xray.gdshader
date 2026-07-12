shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never;
// 纸片角色「穿透」pass：作为 paper_character.gdshader 的 next_pass 挂载。
// 只在角色被其它不透明几何体（SDF 建筑/树/地形）挡住的像素上，画出半透明的角色剪影，
// 让被遮挡的角色仍能被看见。原理：读 DEPTH_TEXTURE 拿到当前屏幕最近的不透明表面深度，
// 与本片元自身深度比较——若最近不透明面更靠近相机（挡在角色前面）才绘制，否则丢弃。
//
// 顶点位移（curl/flutter）必须与主 pass 完全一致，剪影才能与可见立绘严丝合缝对齐，
// 故这里复制了 paper_character.gdshader 的 vertex()。渲染为透明（depth_test/write 关闭），
// 排在所有不透明之后，此时 DEPTH_TEXTURE 已含完整不透明场景深度。

uniform sampler2D albedo_tex : source_color, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec2 quad_size = vec2(2.0, 3.2);
uniform float curl = 0.0;
uniform float flutter_amp = 0.0;
uniform float flutter_speed = 7.0;

// 折纸机关参数与主 pass 完全一致（见 paper_character.gdshader 注释），剪影随折叠同步变形
uniform vec4 fold1 = vec4(0.0, 0.0, 0.0, 1.0);
uniform float fold1_angle = 0.0;
uniform vec4 fold2 = vec4(0.0, 0.0, 0.0, 1.0);
uniform float fold2_angle = 0.0;
uniform float pleat_amp = 0.0;
uniform float pleat_freq = 4.0;
uniform float crumple_amp = 0.0;

// 与主 pass 相同的 sprite-sheet 分格参数（保证剪影与当前动画格同步）
uniform int sheet_cols = 1;
uniform int sheet_rows = 1;
uniform int sheet_frames = 0;
uniform float sheet_fps = 8.0;
uniform float sheet_phase = 0.0;

// 蓝白「透视魔法」观感：发光描边 + 淡填充，不保留角色本色。
uniform vec4 xray_edge : source_color = vec4(0.85, 0.95, 1.0, 1.0); // 描边亮蓝白
uniform vec4 xray_fill : source_color = vec4(0.45, 0.75, 1.0, 1.0); // 填充柔蓝
uniform float xray_edge_alpha = 0.9;   // 描边不透明度
uniform float xray_fill_alpha = 0.18;  // 内部填充不透明度（保留剪影形状，弱于描边）
uniform float xray_edge_px = 2.0;      // 描边宽度（纹素）
uniform float xray_bias = 0.06;        // 自遮挡防抖（米）：小于此深度差视作角色自身，不画

// base UV(0..1 网格) → 图集 UV（分格模式映射到当前动画格；静态整图直接返回）
vec2 sheet_uv(vec2 base) {
	if (sheet_frames <= 0) {
		return base;
	}
	int f = int(mod(floor((TIME + sheet_phase) * sheet_fps), float(sheet_frames)));
	int col = f % sheet_cols;
	int row = f / sheet_cols;
	vec2 grid = vec2(float(sheet_cols), float(sheet_rows));
	vec2 texel = 0.5 / vec2(textureSize(albedo_tex, 0));
	vec2 cell = clamp(base, texel * grid, vec2(1.0) - texel * grid);
	return (vec2(float(col), float(row)) + cell) / grid;
}

float sample_alpha(vec2 base) {
	return texture(albedo_tex, sheet_uv(base)).a;
}

// 与主 pass 逐行一致的折痕函数（paper_character.gdshader）
void apply_fold(inout vec3 v, vec4 crease, float ang, vec2 qs) {
	if (abs(ang) < 1e-4) {
		return;
	}
	vec2 o = vec2(crease.x * qs.x * 0.5, crease.y * qs.y);
	vec2 d = normalize(vec2(crease.z * qs.x * 0.5, crease.w * qs.y));
	vec2 n = vec2(-d.y, d.x);
	float t = dot(v.xy - o, d);
	float dist = dot(v.xy - o, n);
	if (dist <= 0.0) {
		return;
	}
	float c = cos(ang);
	float s = sin(ang);
	v.xy = o + d * t + n * (dist * c - v.z * s);
	v.z = dist * s + v.z * c;
}

void vertex() {
	float xn = VERTEX.x / max(quad_size.x * 0.5, 0.001);
	float yn = clamp(VERTEX.y / max(quad_size.y, 0.001), 0.0, 1.0);
	vec3 v = VERTEX;
	apply_fold(v, fold1, fold1_angle, quad_size);
	apply_fold(v, fold2, fold2_angle, quad_size);
	if (pleat_amp > 0.0) {
		v.z += pleat_amp * (abs(fract(yn * pleat_freq) - 0.5) * 2.0 - 0.5);
	}
	if (crumple_amp > 0.0) {
		v += crumple_amp * 0.5 * vec3(
			sin(VERTEX.x * 13.1 + VERTEX.y * 7.7),
			sin(VERTEX.x * 9.3 - VERTEX.y * 11.9 + 3.1),
			sin(VERTEX.x * 15.7 + VERTEX.y * 5.3 + 1.7));
	}
	VERTEX = v;
	VERTEX.z += curl * xn * xn;
	VERTEX.z += flutter_amp * (1.0 - yn) * sin(yn * 9.0 - TIME * flutter_speed + xn * 1.5);
}

void fragment() {
	// 1) 只在被遮挡处绘制：重建屏幕最近不透明面的视空间 z，与本片元视空间 z 比较
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	float scene_z = view.z / view.w;   // 视空间 z（相机前为负），最近不透明面
	float frag_z = VERTEX.z;           // 本片元视空间 z
	// 有东西挡在角色前面 => 最近不透明面更靠近相机 => scene_z 更接近 0（大于 frag_z）
	if (scene_z <= frag_z + xray_bias) {
		discard;
	}

	// 2) 用立绘 alpha 裁出角色轮廓，超出即丢弃
	if (sample_alpha(UV) < 0.5) {
		discard;
	}

	// 3) 描边检测：本像素在形内、若邻域出现形外像素则为轮廓边缘。
	// 步长按「基 UV 下的纹素」算（分格模式一格占 1/grid，故乘 grid 还原到整图纹素）。
	vec2 grid = (sheet_frames > 0) ? vec2(float(sheet_cols), float(sheet_rows)) : vec2(1.0);
	vec2 step_uv = xray_edge_px * grid / vec2(textureSize(albedo_tex, 0));
	float outside =
		  (1.0 - step(0.5, sample_alpha(UV + vec2( step_uv.x, 0.0))))
		+ (1.0 - step(0.5, sample_alpha(UV + vec2(-step_uv.x, 0.0))))
		+ (1.0 - step(0.5, sample_alpha(UV + vec2(0.0,  step_uv.y))))
		+ (1.0 - step(0.5, sample_alpha(UV + vec2(0.0, -step_uv.y))))
		+ (1.0 - step(0.5, sample_alpha(UV + step_uv)))
		+ (1.0 - step(0.5, sample_alpha(UV - step_uv)))
		+ (1.0 - step(0.5, sample_alpha(UV + vec2( step_uv.x, -step_uv.y))))
		+ (1.0 - step(0.5, sample_alpha(UV + vec2(-step_uv.x,  step_uv.y))));
	float edge = clamp(outside, 0.0, 1.0); // 邻域有形外像素 => 边缘

	ALBEDO = mix(xray_fill.rgb, xray_edge.rgb, edge);
	ALPHA = mix(xray_fill_alpha, xray_edge_alpha, edge);
}
