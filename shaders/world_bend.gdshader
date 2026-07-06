shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled, world_vertex_coords;
// World-bending（"小星球"弯曲）：按离世界原点（玩家——渲染是玩家居中的，见 chunk_manager）
// 的水平距离平方把顶点往下压，远处地面向下弯出弧形地平线。
// 用 world_vertex_coords 在世界空间位移：相机 pass 与 shadow pass 几何一致，阴影不错位
// （旧版在视图空间位移，shadow pass 的"视图"是光源 → 阴影错位，只能关阴影）。
// 逻辑/数据仍是纯平铺环面，只有渲染弯曲。

uniform vec3 albedo : source_color = vec3(0.46, 0.72, 0.40);
uniform sampler2D albedo_tex : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_depth : hint_range(-2.0, 2.0) = 0.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform vec2 uv_scale = vec2(1.0);
uniform float curvature = 0.018;
// 顶点色混合开关（SdfStaticBaker 烘焙网格用：颜色在顶点色里；默认 0 不影响存量材质）
uniform float vertex_color_mix : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

void fragment() {
	vec2 uv = UV * uv_scale;
	ALBEDO = albedo * texture(albedo_tex, uv).rgb * mix(vec3(1.0), COLOR.rgb, vertex_color_mix);
	ROUGHNESS = roughness;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
}
