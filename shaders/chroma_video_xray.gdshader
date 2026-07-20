shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never;
// 焦点视频 LOD 的「穿透」pass：作为 chroma_video.gdshader 的 next_pass 挂载,让视频英雄被
// 房子/树挡住时也画半透明蓝白剪影(与常规图集角色 paper_xray 一致)。
// 与 paper_xray 同一套「读 DEPTH_TEXTURE 判遮挡 + 描边检测 + 蓝白透视观感」,区别只在:
//   ① 剪影形状来自 video_tex 的抠绿 alpha(绿→透明),不是图集 alpha;
//   ② 视频档是平面 quad、无 curl/flutter/fold 顶点位移,故用默认顶点(不复制 paper 位移)。
uniform sampler2D video_tex : source_color, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float key_lo = 0.04;   // 与 chroma_video.gdshader 同口径的绿主导阈值
uniform float key_hi = 0.18;
uniform vec4 xray_edge : source_color = vec4(0.85, 0.95, 1.0, 1.0);
uniform vec4 xray_fill : source_color = vec4(0.45, 0.75, 1.0, 1.0);
uniform float xray_edge_alpha = 0.9;
uniform float xray_fill_alpha = 0.18;
uniform float xray_edge_px = 2.0;
uniform float xray_bias = 0.06;

// 抠绿 alpha：与主 pass 同一判定,绿主导处透明,得到角色剪影。
float chroma_alpha(vec2 uv) {
	vec4 c = texture(video_tex, uv);
	float greenness = c.g - max(c.r, c.b);
	return 1.0 - smoothstep(key_lo, key_hi, greenness);
}

void fragment() {
	// 1) 只在被遮挡处绘制（同 paper_xray）：屏幕最近不透明面视空间 z 与本片元 z 比较
	float raw = texture(depth_tex, SCREEN_UV).r;
	vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, raw, 1.0);
	vec4 view = INV_PROJECTION_MATRIX * ndc;
	float scene_z = view.z / view.w;
	float frag_z = VERTEX.z;
	if (scene_z <= frag_z + xray_bias) {
		discard;
	}
	// 2) 抠绿 alpha 裁出角色轮廓
	if (chroma_alpha(UV) < 0.5) {
		discard;
	}
	// 3) 描边检测：邻域出现形外像素即为轮廓边缘
	vec2 step_uv = xray_edge_px / vec2(textureSize(video_tex, 0));
	float outside =
		  (1.0 - step(0.5, chroma_alpha(UV + vec2( step_uv.x, 0.0))))
		+ (1.0 - step(0.5, chroma_alpha(UV + vec2(-step_uv.x, 0.0))))
		+ (1.0 - step(0.5, chroma_alpha(UV + vec2(0.0,  step_uv.y))))
		+ (1.0 - step(0.5, chroma_alpha(UV + vec2(0.0, -step_uv.y))))
		+ (1.0 - step(0.5, chroma_alpha(UV + step_uv)))
		+ (1.0 - step(0.5, chroma_alpha(UV - step_uv)))
		+ (1.0 - step(0.5, chroma_alpha(UV + vec2( step_uv.x, -step_uv.y))))
		+ (1.0 - step(0.5, chroma_alpha(UV + vec2(-step_uv.x,  step_uv.y))));
	float edge = clamp(outside, 0.0, 1.0);
	ALBEDO = mix(xray_fill.rgb, xray_edge.rgb, edge);
	ALPHA = mix(xray_fill_alpha, xray_edge_alpha, edge);
}
