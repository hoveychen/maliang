shader_type spatial;
render_mode unshaded, cull_disabled;
// 纸片角色着色器：细分 QuadMesh 上做顶点位移，表达「纸」的卷曲/飘动/折叠。
// 卷曲/飘动位移只走本地 Z（朝/背相机），脚底始终贴地；折纸机关（折痕/风琴/揉皱）
// 会动 XY——折起来轮廓本来就该变。
// 双面渲染：背面 UV 天然镜像，配合节点 rotation.y 翻面即得朝左（美术统一朝右）。
// unshaded 与旧 Sprite3D(shaded=false) 表现一致；alpha scissor 等价 ALPHA_CUT_DISCARD。

uniform sampler2D albedo_tex : source_color, filter_linear;
uniform vec4 modulate : source_color = vec4(1.0);
uniform vec2 quad_size = vec2(2.0, 3.2); // 网格世界尺寸（米），归一化顶点坐标用
uniform float curl = 0.0;         // 水平卷曲（米）：左右边缘向 Z 弯，待机呼吸微卷
uniform float flutter_amp = 0.0;  // 走路飘动幅度（米）：下摆重、头顶轻的行波
uniform float flutter_speed = 7.0;

// 折纸机关（折痕×2/风琴折/揉皱），纯顶点位移，动作层经 PaperCharacter.set_paper_fold 驱动。
// 折痕在归一化纸面坐标定义：xy=痕上一点(xn∈-1..1, yn∈0..1)，zw=痕方向；痕的法侧
// （方向逆时针 90°）那半张纸绕痕线（米空间）翻 *_angle 弧度（正=朝相机 +Z 折）。
// ⚠️ xray pass（paper_xray.gdshader）复制了同一套 vertex 位移，两边必须同步改。
uniform vec4 fold1 = vec4(0.0, 0.0, 0.0, 1.0);
uniform float fold1_angle = 0.0;
uniform vec4 fold2 = vec4(0.0, 0.0, 0.0, 1.0);
uniform float fold2_angle = 0.0;
uniform float pleat_amp = 0.0;   // 风琴折深度（米），沿高度 zigzag
uniform float pleat_freq = 4.0;  // 风琴折折数（整张高度内的周期数）
uniform float crumple_amp = 0.0; // 揉皱幅度（米）：位置哈希噪声位移

// 动画 sprite-sheet：sheet_frames>0 时把 albedo_tex 当作 cols×rows 图集，
// 按 TIME*fps 推进当前格并把 UV 映射到该格；=0 时按整张静态贴图采样（原行为不变）。
//
// 多段（idle/moving/talking）：三段的帧在同一张图集里按行主序连续排布，
// sheet_start = 当前段首帧的全局下标、sheet_frames = 当前段的帧数。切段只改这两个
// uniform（三段共用裁剪盒 → cell 尺寸相同 → 几何不用重算）。单段图集 sheet_start=0。
uniform int sheet_cols = 1;
uniform int sheet_rows = 1;
uniform int sheet_start = 0;   // 当前段首帧下标
uniform int sheet_frames = 0;  // 当前段帧数（不是整张图集的帧数）
uniform float sheet_fps = 8.0;
uniform float sheet_phase = 0.0; // 每角色相位偏移（秒），避免同款立绘齐步走

// 痕一侧绕痕线硬折：归一化痕坐标换算到米空间后，对法侧顶点做绕线旋转。
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
	float xn = VERTEX.x / max(quad_size.x * 0.5, 0.001); // -1(左)..1(右)
	float yn = clamp(VERTEX.y / max(quad_size.y, 0.001), 0.0, 1.0); // 0 脚底..1 头顶
	// 折纸先于卷曲/飘动：折痕定宏观形，柔性位移叠其上
	vec3 v = VERTEX;
	apply_fold(v, fold1, fold1_angle, quad_size);
	apply_fold(v, fold2, fold2_angle, quad_size);
	if (pleat_amp > 0.0) {
		// z 折深 + 相位错开的 x 锯齿：unshaded 材质正面看不出 z 折，锯齿剪影才读得出"风琴"
		v.z += pleat_amp * (abs(fract(yn * pleat_freq) - 0.5) * 2.0 - 0.5);
		v.x += pleat_amp * 0.6 * (abs(fract(yn * pleat_freq + 0.25) - 0.5) * 2.0 - 0.5);
	}
	if (crumple_amp > 0.0) {
		// y 分量按 yn 锚在脚底：底边噪声往下拱会把纸压进地面
		v += crumple_amp * 0.5 * vec3(
			sin(VERTEX.x * 13.1 + VERTEX.y * 7.7),
			sin(VERTEX.x * 9.3 - VERTEX.y * 11.9 + 3.1) * yn,
			sin(VERTEX.x * 15.7 + VERTEX.y * 5.3 + 1.7));
	}
	VERTEX = v;
	VERTEX.z += curl * xn * xn;
	VERTEX.z += flutter_amp * (1.0 - yn) * sin(yn * 9.0 - TIME * flutter_speed + xn * 1.5);
}

void fragment() {
	vec2 uv = UV;
	if (sheet_frames > 0) {
		int f = sheet_start + int(mod(floor((TIME + sheet_phase) * sheet_fps), float(sheet_frames)));
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
