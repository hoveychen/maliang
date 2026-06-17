shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;
// World-bending（"小星球"弯曲）：在视图空间按离相机的水平距离平方把顶点往下压，
// 远处地面向下弯出弧形地平线。逻辑/数据仍是纯平铺环面，只有渲染弯曲。
// 直接写 POSITION（裁剪空间），绕过默认 MODELVIEW→PROJECTION。

uniform vec3 albedo : source_color = vec3(0.46, 0.72, 0.40);
uniform float curvature = 0.018;

void vertex() {
	vec3 vv = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vv.y -= curvature * (vv.x * vv.x + vv.z * vv.z);
	POSITION = PROJECTION_MATRIX * vec4(vv, 1.0);
}

void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = 0.95;
}
