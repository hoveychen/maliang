shader_type spatial;
render_mode cull_disabled, unshaded, world_vertex_coords;
// tile 边缘贴纸竖片（docs/sticker-items-design.md §3）：
// 顶点弯曲与 world_bend.gdshader 同式（跟随小星球曲率，否则远处贴纸浮空），
// alpha scissor 硬边镂空（白描边贴纸不需要半透明排序），双面渲染（背面镜像可接受）。

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform float curvature = 0.0015; // 与 BendMat.CURVATURE 一致，chunk_manager 建材质时对齐

void vertex() {
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
