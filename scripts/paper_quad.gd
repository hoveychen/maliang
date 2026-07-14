class_name PaperQuad
extends RefCounted
## 「前后三明治」纸片贴片的共享构造——两处复用同一套几何/材质数学：
##   1) 角色贴纸附着（PaperCharacter.attach_sticker，character-anchors）
##   2) 组合物零件（ComposedProp，积木式造物 B1）
## 抽取前这套数学内联在 attach_sticker 里（docs/character-anchors-design.md §4）；
## 组合零件挂到骨架槽位与贴纸挂到立绘锚点是逐字相同的换算，故收敛为一个 helper。
##
## 结构（贴纸贴在会翻面/倾斜的纸片上的必要构造）：一个 holder(Node3D) 挂前后两片 QuadMesh，
## 分处 ±z（防 z-fight），背片预转 rotation.y=PI——翻面(父 rotation.y=PI)后总有一片朝相机，
## 且背面看到的是与角色本身镜像一致的镜像贴纸。两片都关阴影、unshaded、alpha scissor 抠边。

## 贴片离主面片的前后距离（米），防 z-fight。与 PaperCharacter.STICKER_Z 同值。
const Z_OFFSET := 0.02

## 造一个「前后三明治」贴片 holder（Node3D，含前后两片 MeshInstance3D）。
## tex：贴片纹理（含白描边/透明底）；w,h：贴片世界尺寸（米）；z：前后偏移（缺省 Z_OFFSET）。
## 返回的 holder 未定位（position=0）——调用方负责摆到锚点/槽位。holder 记 meta "quad_h"=h 供定位用。
static func make_sandwich(tex: Texture2D, w: float, h: float, z: float = Z_OFFSET) -> Node3D:
	var holder := Node3D.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.albedo_texture = tex
	var q := QuadMesh.new()
	q.size = Vector2(w, h)
	q.material = mat
	for side in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.position = Vector3(0.0, 0.0, z * side)
		if side < 0.0:
			mi.rotation.y = PI # 背片朝后：翻面时顶上，镜像与主面片一致
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
	holder.set_meta("quad_h", h)
	return holder
