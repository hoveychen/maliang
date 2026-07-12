shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, world_vertex_coords;
// 地形材质（themed-terrain P1）：顶面/侧壁贴图按 per-tile 层索引从 Texture2DArray 采样，
// 「哪种地形贴图」（无上限，数组层）与「autotile 几何 cell」（atlas，≤8 渲染角色）解耦。
// - COLOR.r → 本 quad 的贴图层索引（层/255）：顶面 quad = tile 顶面层，
//   崖壁 quad = 被抬高 tile 的侧壁层（见 TerrainTextures.top_layer/side_layer）。
// - UV      → 控制图 atlas cell（R 主体域 / G 描边 / B 渲染角色÷8 / A 明暗×0.5）
// - UV2     → 逻辑世界米坐标（玩家居中每帧重摆，用渲染坐标会游动；平铺周期整除环面跨度即无缝）
// col = layer_tint[层] × mix(1, tex/layer_mean[层], detail_strength)；草区恒采 GRASS 层。
// ⚠ P0 审定贴图已把 tint 烘入，对应层的 tint/mean 传白 → shader 不再二次上色（无双重上色）。
// 弯曲：与 world_bend.gdshader 同一公式（世界空间位移，shadow pass 几何一致）。

uniform sampler2D control_tex : filter_linear_mipmap, repeat_disable;  // 控制图选域用（老 Mali 上大覆盖面最贵的采样）
uniform sampler2DArray top_array : source_color, filter_linear_mipmap, repeat_enable;  // 顶面+侧壁贴图数组（层序 = TerrainTextures.LAYER_*）
// 逐层色调 / 均值（TerrainTextures.layer_tints_linear/means_linear 传入，已 sRGB→线性；下标 = 层索引）。
uniform vec3 layer_tint[16];
uniform vec3 layer_mean[16];
uniform vec3 path_rim : source_color = vec3(0.97, 0.92, 0.74);   // 路亮描边
uniform vec3 cliff_rim : source_color = vec3(0.63, 0.86, 0.42);  // 崖缘亮草包边
uniform float tile_period = 10.0;      // 贴图平铺周期（米）；须整除环面跨度 150
uniform float detail_strength = 0.8;
// 低配档（AdaptiveQuality）：body（路/崖壁/地表）不采数组细节改平色 tint，每像素省一次采样；
// 草地细节保留（占屏大头，是水彩质感的主体）。
uniform bool low_detail = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float curvature = 0.0015;

const int GRASS_LAYER = 0;     // = TerrainTextures.LAYER_GRASS
const int ROLE_CLIFF_RIM = 3;  // = TerrainAtlas.ROLE_CLIFF_RIM（B*8；仅用于选 rim 色）

varying flat int v_layer;

void vertex() {
	v_layer = int(round(COLOR.r * 255.0));
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

vec3 layer_col(int layer, vec2 uv) {
	vec3 tex = texture(top_array, vec3(uv, float(layer))).rgb;
	vec3 det = mix(vec3(1.0), tex / max(layer_mean[layer], vec3(0.001)), detail_strength);
	return layer_tint[layer] * det;
}

void fragment() {
	vec4 ctl = texture(control_tex, UV);
	int role = int(round(ctl.b * 8.0));
	vec2 wuv = UV2 / tile_period;
	vec3 grass = layer_col(GRASS_LAYER, wuv);              // 万物草底（过渡 cell 的草区）
	vec3 body = low_detail ? layer_tint[v_layer] : layer_col(v_layer, wuv);
	vec3 col = mix(grass, body, ctl.r);                    // 主体域 R 混草底/body
	col = mix(col, role == ROLE_CLIFF_RIM ? cliff_rim : path_rim, ctl.g);  // 描边
	col *= ctl.a * 2.0;                                    // 明暗纹样
	ALBEDO = col;
	ROUGHNESS = roughness;
}
