shader_type spatial;
render_mode unshaded, cull_disabled;
// 纸片角色着色器：细分 QuadMesh 上做顶点位移，表达「纸」的卷曲/飘动。
// 位移只走本地 Z（朝/背相机），不动 XY——脚底始终贴地、轮廓宽度不变。
// 双面渲染：背面 UV 天然镜像，配合节点 rotation.y 翻面即得朝左（美术统一朝右）。
// unshaded 与旧 Sprite3D(shaded=false) 表现一致；alpha scissor 等价 ALPHA_CUT_DISCARD。

uniform sampler2D albedo_tex : source_color, filter_linear;
uniform vec4 modulate : source_color = vec4(1.0);
uniform vec2 quad_size = vec2(2.0, 3.2); // 网格世界尺寸（米），归一化顶点坐标用
uniform float curl = 0.0;         // 水平卷曲（米）：左右边缘向 Z 弯，待机呼吸微卷
uniform float flutter_amp = 0.0;  // 走路飘动幅度（米）：下摆重、头顶轻的行波
uniform float flutter_speed = 7.0;

// idle 动画 sprite-sheet：sheet_frames>0 时把 albedo_tex 当作 cols×rows 图集，
// 按 TIME*fps 推进当前格并把 UV 映射到该格；=0 时按整张静态贴图采样（原行为不变）。
uniform int sheet_cols = 1;
uniform int sheet_rows = 1;
uniform int sheet_frames = 0;
uniform float sheet_fps = 8.0;
uniform float sheet_phase = 0.0; // 每角色相位偏移（秒），避免同款立绘齐步走

void vertex() {
	float xn = VERTEX.x / max(quad_size.x * 0.5, 0.001); // -1(左)..1(右)
	float yn = clamp(VERTEX.y / max(quad_size.y, 0.001), 0.0, 1.0); // 0 脚底..1 头顶
	VERTEX.z += curl * xn * xn;
	VERTEX.z += flutter_amp * (1.0 - yn) * sin(yn * 9.0 - TIME * flutter_speed + xn * 1.5);
}

void fragment() {
	vec2 uv = UV;
	if (sheet_frames > 0) {
		int f = int(mod(floor((TIME + sheet_phase) * sheet_fps), float(sheet_frames)));
		int col = f % sheet_cols;
		int row = f / sheet_cols;
		// UV(0..1) 映射进第 (col,row) 格；内缩半个纹素防线性采样越格串帧
		vec2 grid = vec2(float(sheet_cols), float(sheet_rows));
		vec2 texel = 0.5 / vec2(textureSize(albedo_tex, 0));
		vec2 cell = clamp(UV, texel * grid, vec2(1.0) - texel * grid);
		uv = (vec2(float(col), float(row)) + cell) / grid;
	}
	vec4 c = texture(albedo_tex, uv) * modulate;
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
