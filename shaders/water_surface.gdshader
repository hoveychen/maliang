shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled, world_vertex_coords;
// 半透明水面（chunk 内水 tile 上覆盖的独立 mesh，chunk_manager._water_mesh 生成）：
// - 顶点色 COLOR.r = 深度归一(depth/MAX_DEPTH，四邻水 tile 均值)——浅处透湖床、深处压深色
// - UV → 控制图 atlas 水 cell：G 通道 = 沿岸圆角泡沫带（autotile 角变体，子 tile 精度，
//   窄溪只在贴岸处起沫），随时间轻微涌动
// - UV2 = 逻辑世界米坐标（同 terrain_ground：玩家居中重摆不游动），双层错速滚动
//   水彩水贴图 = 流动波纹；均值归一后只留笔触，色调由 shallow/deep 渐变决定
// - 菲涅尔：掠射角混入天空色并提高不透明度（远处水面像镜面贴天）
// - 顶点微幅起伏（按 UV2 相位，非渲染坐标——避免玩家移动时波形游动）
// 弯曲：与 world_bend.gdshader 同一公式。

uniform sampler2D control_tex : filter_linear_mipmap, repeat_disable;  // 控制图选域用，无需各向异性（老 Mali 上大覆盖面最贵的采样）
uniform sampler2D water_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 water_mean : source_color = vec3(0.282, 0.478, 0.518);
uniform vec3 shallow_color : source_color = vec3(0.42, 0.72, 0.88);
uniform vec3 deep_color : source_color = vec3(0.13, 0.35, 0.62);
uniform vec3 foam_color : source_color = vec3(0.92, 0.975, 1.0);
uniform vec3 sky_tint : source_color = vec3(0.62, 0.82, 0.97); // 与 world.gd SKY_HORIZON_COLOR 对齐
uniform float tile_period = 10.0;
uniform float detail_strength = 0.85;
// AdaptiveQuality T2 弱机档：省掉第二层错速细节采样（同 terrain_ground.low_detail）
uniform bool low_detail = false;
uniform float curvature = 0.0015;

// —— 纸艺化（与 world_bend/terrain_ground 同一开关体系，默认 0 = 观感不变）——
// 水的纸模语法：深浅渐变量化成离散台阶（立体书里层层剪纸的水）+ 压平波纹 + 纸纹/卡纸色调。
// paper_bands 在本 shader 量化的是「深度分层」而非光照（水面颜色几乎全由 albedo 决定）。
uniform float paper_bands : hint_range(0.0, 8.0) = 0.0;
uniform float paper_grain : hint_range(0.0, 1.0) = 0.0;
uniform float paper_tone : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	VERTEX.y += sin(TIME * 1.2 + (UV2.x + UV2.y) * 0.9) * 0.05;
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

float paper_hash(vec2 q) {
	return fract(sin(dot(q, vec2(127.1, 311.7))) * 43758.5453);
}

float paper_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(paper_hash(i), paper_hash(i + vec2(1.0, 0.0)), f.x),
		mix(paper_hash(i + vec2(0.0, 1.0)), paper_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 wuv = UV2 / tile_period;
	vec3 d1 = texture(water_tex, wuv + TIME * vec2(0.014, 0.009)).rgb / water_mean;
	vec3 d2 = low_detail ? d1 : texture(water_tex, wuv * 1.7 - TIME * vec2(0.011, 0.016)).rgb / water_mean;
	vec3 det = mix(vec3(1.0), (d1 + d2) * 0.5, detail_strength);
	float depth01 = COLOR.r;
	if (paper_bands > 0.5) {
		// 深浅量化成剪纸台阶 + 压平波纹（纸片水是平的，只留一点笔触呼吸）
		depth01 = floor(depth01 * paper_bands + 0.5) / paper_bands;
		det = mix(vec3(1.0), det, 0.35);
	}
	vec3 col = mix(shallow_color, deep_color, depth01) * det;
	if (paper_tone > 0.001) {
		float plum = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(col, mix(col, vec3(plum), 0.25) * 1.06 + 0.02, paper_tone);
	}
	if (paper_grain > 0.001) {
		float g = 0.65 * paper_noise(UV2 * 0.45) + 0.35 * paper_noise(UV2 * 1.8);
		col *= mix(1.0, 0.82 + 0.36 * g, paper_grain);
	}
	float fr = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	col = mix(col, sky_tint, fr * 0.5);
	// 岸边白描边（Pokopia 化 P7，serebii_12）：贴岸一条恒亮实心白水线（干净轮廓线，
	// 不是碎泡沫）。涌动只调制带宽相位（呼吸，沿岸相位用逻辑坐标，环面无缝）——
	// 旧版拿 wob 乘泡沫本体把线压暗洗成淡蓝雾，白线必须恒亮才立得住。
	float g = texture(control_tex, UV).g;
	float breathe = 0.06 * sin(TIME * 1.6 + (UV2.x + UV2.y) * 2.4);
	float foam = smoothstep(0.30 + breathe, 0.62 + breathe, g);
	col = mix(col, foam_color, foam);
	// 波峰高光星点：双层细节同时偏亮处提一把
	col += step(2.6, d1.g + d2.g) * 0.12;
	ALBEDO = col;
	// 白线处提不透明度（0.45）：实心线不能透出湖床把白洗蓝
	ALPHA = clamp(mix(0.55, 0.88, depth01) + fr * 0.15 + foam * 0.45, 0.0, 0.95);
	ROUGHNESS = 0.3;
}
