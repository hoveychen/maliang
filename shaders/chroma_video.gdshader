shader_type spatial;
render_mode unshaded, cull_disabled;
// ★不透明 + alpha scissor（与 paper_character.gdshader 同）——不是 blend_mix 透明。
// 透明档会让视频英雄进「透明队列」，与同为透明的脚下伪影/物件阴影（blob_shadow.gdshader 也是
// blend_mix）按物体中心距离排序：地面阴影中心比直立牌子中心更近相机时会画到英雄身上（老板实测
// 「视频英雄被物品阴影遮住」）。图集档是不透明、先写深度，阴影天然被挡住、无此病。故这里对齐图集：
// 不透明 + ALPHA_SCISSOR 硬切（抠绿边缘硬一点，与图集一致、观感可接受），换回正确的深度遮挡。
// 焦点角色真视频 LOD 的抠绿着色器（见 docs/video-hero-lod-design.md）。
// 输入是 VideoStreamPlayer 逐帧解码出的绿幕视频纹理（video_tex，每帧由 PaperCharacter
// 在 _process 里重设）；按「绿主导」判透明剔掉绿幕，despill 压残绿。观感 2026-07-20 spike 真机验过。
//
// 与 paper_character.gdshader 同一套朝向约定：cull_disabled 双面渲染，背面 UV 天然镜像，
// 配合节点 rotation.y=PI 翻面即得朝左（美术统一朝右）。这里不做卷曲/飘动顶点位移——
// 视频本身就是动画，纸片柔性演出留给图集档。
uniform sampler2D video_tex : source_color, filter_linear;
uniform float key_lo = 0.04;   // 绿主导阈值下界
uniform float key_hi = 0.18;   // 上界（之间羽化）

void fragment() {
	vec4 c = texture(video_tex, UV);
	float greenness = c.g - max(c.r, c.b);
	float a = 1.0 - smoothstep(key_lo, key_hi, greenness);
	if (greenness > 0.0) {              // despill：残绿往灰压
		float m = max(c.r, c.b);
		c.g = mix(c.g, m, clamp(greenness * 3.0, 0.0, 1.0));
	}
	ALBEDO = c.rgb;
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;  // 硬切 → 不透明 cutout（同图集档），写深度、正确遮挡阴影
}
