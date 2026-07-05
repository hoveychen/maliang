shader_type spatial;
render_mode cull_front, unshaded;
// SDF blend-shell 描边 pass（挂主材质 next_pass）：顶点吸附到 SDF 的 +outline_width
// 等值面而非沿法线外推——偏移面在凹接缝处依然连续，不会像法线外推那样开裂/自交。
// cull_front 只留背面壳，从正面看即均匀描边。

#include "res://shaders/sdf_field.gdshaderinc"

uniform float outline_width : hint_range(0.0, 0.2) = 0.035;
uniform vec4 outline_color : source_color = vec4(0.16, 0.11, 0.13, 1.0);

void vertex() {
	int pi = int(UV2.x + 0.5);
	vec3 shell = quat_rotate(prim_rot[pi], VERTEX) + prim_pos[pi].xyz;
	vec3 n;
	vec3 p = sdf_snap(shell, outline_width, n);
	VERTEX = apply_bend(p, MODEL_MATRIX);
	NORMAL = n;
}

void fragment() {
	ALBEDO = outline_color.rgb;
}
