shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, world_vertex_coords;
// 脚下伪影（blob shadow）：实时定向阴影在老移动 GPU 上一开就 ~2.5 倍帧开销
// （Mali-G76 实测 7↔18fps，与投影几何量/软硬过滤无关），全场景改平光 + 角色脚下暗斑。
// 跟 world_bend.gdshader 同一条世界空间弯曲项，远处不悬空。

// curvature 置 0 = 关掉本 shader 的弯曲：角色节点已被 world._place_on_bent_ground
// CPU 预下压（子节点跟着沉），再弯一次就双重下坠钻进地里；SdfProp 节点没预压才需要弯。
uniform float curvature = 0.0015;
uniform float strength : hint_range(0.0, 1.0) = 0.38;

void vertex() {
	VERTEX.y -= curvature * dot(VERTEX.xz, VERTEX.xz);
}

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = vec3(0.0);
	// 注意 smoothstep 边界必须 edge0<edge1（反着写是 GLSL 未定义行为，部分驱动恒 0）
	ALPHA = strength * (1.0 - smoothstep(0.35, 1.0, d));
}
