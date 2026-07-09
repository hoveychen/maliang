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

// 与主 pass 相同的 sprite-sheet 分格参数（保证剪影与当前动画格同步）
uniform int sheet_cols = 1;
uniform int sheet_rows = 1;
uniform int sheet_frames = 0;
uniform float sheet_fps = 8.0;
uniform float sheet_phase = 0.0;

// 穿透观感调参
uniform vec4 xray_tint : source_color = vec4(0.55, 0.85, 1.0, 0.0); // rgb=着色, a=着色混入比(0=保留原色)
uniform float xray_alpha = 0.42;   // 剪影不透明度
uniform float xray_bias = 0.06;    // 自遮挡防抖（米）：小于此深度差视作角色自身，不画

void vertex() {
	float xn = VERTEX.x / max(quad_size.x * 0.5, 0.001);
	float yn = clamp(VERTEX.y / max(quad_size.y, 0.001), 0.0, 1.0);
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

	// 2) 用立绘 alpha 裁出角色轮廓（复制主 pass 的分格 UV）
	vec2 uv = UV;
	if (sheet_frames > 0) {
		int f = int(mod(floor((TIME + sheet_phase) * sheet_fps), float(sheet_frames)));
		int col = f % sheet_cols;
		int row = f / sheet_cols;
		vec2 grid = vec2(float(sheet_cols), float(sheet_rows));
		vec2 texel = 0.5 / vec2(textureSize(albedo_tex, 0));
		vec2 cell = clamp(UV, texel * grid, vec2(1.0) - texel * grid);
		uv = (vec2(float(col), float(row)) + cell) / grid;
	}
	vec4 c = texture(albedo_tex, uv);
	if (c.a < 0.5) {
		discard;
	}

	ALBEDO = mix(c.rgb, xray_tint.rgb, xray_tint.a);
	ALPHA = xray_alpha;
}
