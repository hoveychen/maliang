shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, world_vertex_coords;
// 地形专用 world-bending 材质：颜色 = 调色板 tint × 水彩贴图细节 × 控制图明暗。
// - UV  → 控制图 atlas cell（TerrainAtlas：R 主体域 / G 描边 / B 类型/8 / A 明暗×0.5）
// - UV2 → 逻辑世界米坐标（区块局部 + wrapped 区块偏移烘进 mesh——渲染是玩家居中
//   每帧重摆区块，用渲染坐标采样会"游动"，逻辑坐标恒定；平铺周期整除环面跨度即无缝）
// - 贴图细节 = tex / mean（均值归一，watercolor 包整体偏暗，除均值后只留笔触变化，
//   亮度基调仍由 tint 决定），detail_strength 控制细节强度。
// 弯曲：与 world_bend.gdshader 同一公式（世界空间位移，shadow pass 几何一致）。

uniform sampler2D control_tex : filter_linear_mipmap, repeat_disable;  // 控制图选域用，无需各向异性（老 Mali 上大覆盖面最贵的采样）
uniform sampler2D grass_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D dirt_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D stone_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 grass_mean : source_color = vec3(0.282, 0.361, 0.153);
uniform vec3 dirt_mean : source_color = vec3(0.302, 0.188, 0.141);
uniform vec3 stone_mean : source_color = vec3(0.357, 0.357, 0.380);
uniform vec3 grass_tint : source_color = vec3(0.545, 0.78, 0.47);
uniform vec3 path_tint : source_color = vec3(0.87, 0.77, 0.55);
uniform vec3 bed_tint : source_color = vec3(0.76, 0.69, 0.55);
uniform vec3 lip_tint : source_color = vec3(0.66, 0.55, 0.38);
uniform vec3 wall_tint : source_color = vec3(0.60, 0.49, 0.35);
uniform vec3 path_rim : source_color = vec3(0.95, 0.885, 0.68);
uniform vec3 cliff_rim : source_color = vec3(0.44, 0.63, 0.37);
// 新增地表 body-type tint（world-themes P1；ty 5=沙 6=雪 7=瓷砖，复用 dirt/stone 细节）
uniform vec3 sand_tint : source_color = vec3(0.90, 0.80, 0.55);
uniform vec3 snow_tint : source_color = vec3(0.93, 0.95, 0.99);
uniform vec3 tile_tint : source_color = vec3(0.72, 0.74, 0.78);
uniform float tile_period = 10.0;      // 贴图平铺周期（米）；须整除环面跨度 150
uniform float detail_strength = 0.8;
// 低配档（AdaptiveQuality T2）：路/崖壁不采第二张细节贴图改平色 tint，
// 每像素省 1~2 次采样；草地细节保留（占屏大头，是水彩质感的主体）。
uniform bool low_detail = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float curvature = 0.0015;

void vertex() {
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

vec3 detail(sampler2D tex, vec2 uv, vec3 mean) {
	return mix(vec3(1.0), texture(tex, uv).rgb / max(mean, vec3(0.001)), detail_strength);
}

void fragment() {
	vec4 ctl = texture(control_tex, UV);
	int ty = int(round(ctl.b * 8.0));
	vec2 wuv = UV2 / tile_period;
	vec3 base = grass_tint * detail(grass_tex, wuv, grass_mean);
	// body-type → tint：1 路 2 湖床 3 崖唇 4 崖壁 5 沙 6 雪 7 瓷砖
	vec3 body_tint = ty == 1 ? path_tint : (ty == 2 ? bed_tint : (ty == 3 ? lip_tint
			: (ty == 4 ? wall_tint : (ty == 5 ? sand_tint : (ty == 6 ? snow_tint : tile_tint)))));
	// 细节贴图：崖壁/雪/瓷砖用 stone（石质），其余用 dirt（土质）；沙用 dirt
	bool use_stone = (ty == 4 || ty == 6 || ty == 7);
	vec3 body_det = low_detail ? vec3(1.0)
			: (use_stone ? detail(stone_tex, wuv, stone_mean) : detail(dirt_tex, wuv, dirt_mean));
	vec3 col = mix(base, body_tint * body_det, ctl.r);
	col = mix(col, ty == 1 ? path_rim : cliff_rim, ctl.g);
	col *= ctl.a * 2.0;
	ALBEDO = col;
	ROUGHNESS = roughness;
}
