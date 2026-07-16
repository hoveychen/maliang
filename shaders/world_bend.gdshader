shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, world_vertex_coords;
// World-bending（"小星球"弯曲）：按离世界原点（玩家——渲染是玩家居中的，见 chunk_manager）
// 的水平距离平方把顶点往下压，远处地面向下弯出弧形地平线。
// 用 world_vertex_coords 在世界空间位移：相机 pass 与 shadow pass 几何一致，阴影不错位
// （旧版在视图空间位移，shadow pass 的"视图"是光源 → 阴影错位，只能关阴影）。
// 逻辑/数据仍是纯平铺环面，只有渲染弯曲。

uniform vec3 albedo : source_color = vec3(0.46, 0.72, 0.40);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;  // 调色板/平色块贴图，各向异性无收益
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_depth : hint_range(-2.0, 2.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform vec2 uv_scale = vec2(1.0);
uniform float curvature = 0.018;
// 顶点色混合开关（SdfStaticBaker 烘焙网格用：颜色在顶点色里；默认 0 不影响存量材质）
uniform float vertex_color_mix : hint_range(0.0, 1.0) = 0.0;

// —— 纸艺化（折纸/手工纸模风）——
// 四个旋钮默认 0 = 观感与旧版一致；BendMat 在 MALIANG_PAPERCRAFT=1 时统一开启。
// 全部是 ALU 运算，无新增纹理采样（grain 是程序化噪声，量产可换 CC0 实拍纸纹）。
uniform float paper_facet : hint_range(0.0, 1.0) = 0.0;  // 折面化法线：光照按面片跳变
uniform float paper_bands : hint_range(0.0, 8.0) = 0.0;  // >0.5 时光照量化成 N 档（卡纸明暗）
uniform float paper_edge : hint_range(0.0, 1.0) = 0.0;   // 折痕白描：几何棱线+轮廓描白（纸模签名）
uniform float paper_grain : hint_range(0.0, 1.0) = 0.0;  // 纸纤维颗粒强度
uniform float paper_tone : hint_range(0.0, 1.0) = 0.0;   // 卡纸色调：轻去饱和+提亮

varying vec3 v_local;  // grain 锚点：模型本地坐标（贴死在物体表面）

void vertex() {
	// grain 不能锚世界坐标：地形/道具是「玩家居中」的——每帧只挪 root.position（chunk_manager.update），
	// 网格顶点烘死一次，于是同一顶点的世界坐标每帧在变，用它采噪声会让颗粒像灰尘随相机游动、贴不住物体。
	// VERTEX 在 world_vertex_coords 下是世界坐标；逆模型变换回本地，grain 就恒定贴在物体表面。
	// （逆矩阵是逐顶点 ALU，道具网格顶点少可忽略；真要抠可换 VERTEX-MODEL_MATRIX[3].xyz，
	//  但那依赖物体旋转/缩放逐帧不变，不如逆变换直白。）
	v_local = (inverse(MODEL_MATRIX) * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

// 单倍频平滑值噪声（8 角 hash 三线性插值），纸纤维用不着更贵的
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

void fragment() {
	vec2 uv = UV * uv_scale;
	ALBEDO = albedo * texture(albedo_tex, uv).rgb * mix(vec3(1.0), COLOR.rgb, vertex_color_mix);
	ROUGHNESS = roughness;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	if (paper_facet > 0.001) {
		// 屏幕导数叉积 = 三角面片法线：平滑网格立刻变硬折面受光（折纸感的本体）
		vec3 fn = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		fn = dot(fn, VERTEX) > 0.0 ? -fn : fn;  // 视空间中相机在原点，法线须朝向相机
		NORMAL = normalize(mix(NORMAL, fn, paper_facet));
	}
	if (paper_tone > 0.001) {
		// 卡纸色调：往灰度方向收一点饱和、稍稍提亮——颜料印在纸上的观感
		float lum = dot(ALBEDO, vec3(0.299, 0.587, 0.114));
		ALBEDO = mix(ALBEDO, mix(ALBEDO, vec3(lum), 0.25) * 1.06 + 0.02, paper_tone);
	}
	if (paper_grain > 0.001) {
		// 两个倍频：粗的出手揉纸的明暗斑，细的出纤维颗粒
		float g = 0.65 * paper_noise(v_local * 2.2) + 0.35 * paper_noise(v_local * 9.0);
		ALBEDO *= mix(1.0, 0.78 + 0.44 * g, paper_grain);
	}
	if (paper_edge > 0.001) {
		// fresnel 对方盒几何几乎无效（可见面不处掠射角）；纸模的白边长在折痕上——
		// 用屏幕空间法线突变（fwidth）检测几何棱线与轮廓，描卡纸切口白。
		float crease = clamp((length(fwidth(NORMAL)) - 0.10) * 3.0, 0.0, 1.0);
		ALBEDO = mix(ALBEDO, vec3(0.96, 0.94, 0.90), crease * paper_edge);
	}
}

void light() {
	// paper_bands=0 时须与内建 diffuse_lambert 逐位一致（clamp(N·L)·ATT·LIGHT_COLOR/PI）
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	if (paper_bands > 0.5) {
		// 量化成 N 档 + 半档软过渡（防远处色阶边缘锯齿闪）
		float q = ndl * paper_bands;
		ndl = clamp((floor(q) + smoothstep(0.4, 0.6, fract(q))) / paper_bands, 0.0, 1.0);
	}
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR / PI;
}
