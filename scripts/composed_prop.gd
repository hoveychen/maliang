class_name ComposedProp
extends Node3D
## 积木式造物（B1，docs/kids-thinking-build-from-parts.md §3.1）组合物渲染器。
## 组合物**永久存成一棵零件树**（renderRef 'composed:'，spec={blueprintId, parts:[{slotId,partId,partRenderRef}]}），
## 不拍平成一张图——轮子事后还能换、车厢还能挪去拼别的（B3 复用/改装）。渲染 = 骨架底板 quad +
## 每个零件一片子 quad，按蓝图槽的归一化位姿（BuildBlueprints）摆位。
##
## 复用 character-anchors 的「前后三明治」贴片数学（PaperQuad.make_sandwich，与角色贴纸同一套 helper）：
## 组合零件挂到骨架槽位 ≡ 贴纸挂到立绘锚点，逐字通用，差别只在锚点来源（蓝图作者预置 vs vision 检测）。
##
## 占位阶段（P3 零件/骨架真图未生成）：零件 renderRef 还是 'part:<id>' 无打包资源 → 用按 id 稳定着色的
## 色块贴片占位（色块跑通渲染管线，各槽位姿可见、可截帧检出）；骨架用淡灰描边框占位。真图 P3 落地后
## 走 PackRegistry / 网络资产，本渲染器不变。

## 组合物世界高度（米）。曾 3.0（≈普通造物档），落地只有一格贴纸大小——孩子帮小猪盖的
## 「最结实的家」与 M2 尾声叙事分量不匹配（老板拍板放大一档）。5.0 ≈ 2.5 格高，
## 与村里 3D 建筑相称；占地随之升 3×3（服务端 creationBuildDef，只影响新落成）。
## 拼装台预览不吃这个尺寸（world._raise_build_preview 缩回 PREVIEW_HEIGHT，别挡问题卡）。
const HEIGHT := 5.0
## 拼装台预览的观感高度（米）：落地尺寸放大后预览保持原 3m 档。
const PREVIEW_HEIGHT := 3.0
## 零件逐层前移（米）防 z-fight，按拼入顺序叠。
const PART_Z_STEP := 0.03
## 高亮发光脉动周期（秒）——拼装台当前要填的槽用它闪，招呼孩子往这儿填。
const GLOW_PERIOD := 1.1

var blueprint_id := ""
var _base_w := HEIGHT
var _base_h := HEIGHT
## slotId → 零件 holder（Node3D 三明治双片）。
var _part_holders := {}
## 当前发光的槽 highlight 节点（拼装台预览用；世界成品无 glow）。
var _glow: Node3D = null
var _glow_t := 0.0

## 从落库 spec 造一个成品组合物（世界渲染入口，chunk_manager / item_icon_capture 用）。
static func from_spec(spec: Dictionary) -> ComposedProp:
	var cp := ComposedProp.new()
	if typeof(spec) == TYPE_DICTIONARY:
		cp._render(String(spec.get("blueprintId", "")), spec.get("parts", []))
	return cp

## 拼装台实时预览：按 blueprintId + 已填槽（filled: slotId → {partId, partRenderRef}）重画。
## 每次 build_prompt 调，增量填的零件即时显现（幂等重建，简单可靠）。
func set_filled(bp_id: String, filled: Dictionary) -> void:
	var parts: Array = []
	for slot_id in filled:
		var v: Dictionary = filled[slot_id]
		parts.append({ "slotId": slot_id, "partId": String(v.get("partId", "")), "partRenderRef": String(v.get("partRenderRef", "")) })
	_render(bp_id, parts)

func _render(bp_id: String, parts: Array) -> void:
	blueprint_id = bp_id
	for c in get_children():
		c.name = c.name + "_old" # 让出名字：同帧重建时新 holder 不被自动改名（预览逐轮重画）
		c.queue_free()
	_part_holders.clear()
	_glow = null
	_add_base()
	var i := 0
	for p in parts:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		_add_part(String(p.get("slotId", "")), String(p.get("partRenderRef", "")), i)
		i += 1

## 骨架底板：占位阶段用淡灰描边框（透明中心，让零件透出来，读作「空轮廓」）。
func _add_base() -> void:
	var tex := _frame_texture()
	var holder := PaperQuad.make_sandwich(tex, _base_w, _base_h, 0.0)
	holder.name = "composed_base"
	add_child(holder)

## 一个零件：按蓝图槽位姿摆到骨架上，逐层前移防 z-fight。
func _add_part(slot_id: String, part_render_ref: String, layer: int) -> void:
	if slot_id.is_empty():
		return
	var pose := BuildBlueprints.slot_pose(blueprint_id, slot_id)
	if pose.is_empty():
		return
	var scale_v := float(pose.get("scale", 1.0))
	var pw := _base_w * scale_v
	var tex := _part_texture(part_render_ref, slot_id)
	var ph := pw * float(tex.get_height()) / float(tex.get_width())
	var holder := PaperQuad.make_sandwich(tex, pw, ph, PART_Z_STEP)
	holder.name = "part_" + slot_id
	holder.position = _slot_local(pose)
	holder.position.z += PART_Z_STEP * float(layer) # 后拼的零件叠在前面
	holder.rotation.z = float(pose.get("rot", 0.0))
	add_child(holder)
	_part_holders[slot_id] = holder

## 归一化槽位姿 → 骨架局部坐标。归一化原点左上（x 右增、y 下增）；骨架底板 QuadMesh 居中于原点，
## 故映射到居中坐标：x=(px-0.5)*w（左负右正）、y=(0.5-py)*h（上正下负）。
func _slot_local(pose: Dictionary) -> Vector3:
	var x := (float(pose.get("x", 0.5)) - 0.5) * _base_w
	var y := (0.5 - float(pose.get("y", 0.5))) * _base_h
	return Vector3(x, y, 0.0)

## 拼装台：点亮当前要填的槽（脉动发光框），招呼孩子往这儿填；空串收起。世界成品不调。
func set_glow_slot(slot_id: String) -> void:
	if _glow != null:
		_glow.queue_free()
		_glow = null
	if slot_id.is_empty():
		return
	var pose := BuildBlueprints.slot_pose(blueprint_id, slot_id)
	if pose.is_empty():
		return
	var scale_v := float(pose.get("scale", 1.0))
	var gw := _base_w * scale_v * 1.35 # 比零件略大，像一圈光晕
	var g := PaperQuad.make_sandwich(_glow_texture(), gw, gw, PART_Z_STEP * 0.5)
	g.name = "slot_glow"
	g.position = _slot_local(pose)
	add_child(g)
	_glow = g
	set_process(true)

func _process(delta: float) -> void:
	if _glow == null:
		set_process(false)
		return
	_glow_t += delta
	var a := 0.35 + 0.35 * (0.5 + 0.5 * sin(_glow_t * TAU / GLOW_PERIOD))
	for c in _glow.get_children():
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null:
			var mat := (mi.mesh as QuadMesh).material as StandardMaterial3D
			if mat != null:
				mat.albedo_color = Color(1.0, 0.92, 0.5, a)

## 零件贴图：真图（P3 落地后走 PackRegistry / 网络）优先；缺失回占位色块（按槽稳定着色）。
func _part_texture(part_render_ref: String, slot_id: String) -> Texture2D:
	var key := part_render_ref.get_slice(":", 1)
	if not key.begins_with("@"): # 打包零件（part:<id>）：P3 落地后 PackRegistry 有资源
		var res := PackRegistry.load_resource(key)
		if res is Texture2D:
			return res
	return _placeholder_texture(slot_id if not key.is_empty() else part_render_ref)

## 占位色块：按 id 稳定取色（不同零件不同色，好分辨），带深一档描边读作「一块零件」。
func _placeholder_texture(seed_str: String) -> Texture2D:
	var h := hash(seed_str)
	var hue := float(posmod(h, 360)) / 360.0
	var col := Color.from_hsv(hue, 0.55, 0.95)
	var edge := Color.from_hsv(hue, 0.7, 0.6)
	var s := 48
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(col)
	for x in range(s):
		for b in range(3):
			img.set_pixel(x, b, edge); img.set_pixel(x, s - 1 - b, edge)
			img.set_pixel(b, x, edge); img.set_pixel(s - 1 - b, x, edge)
	return ImageTexture.create_from_image(img)

## 骨架底板占位：淡灰描边框（透明中心）。
func _frame_texture() -> Texture2D:
	var s := 64
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var edge := Color(0.6, 0.6, 0.62, 0.5)
	for x in range(s):
		for b in range(2):
			img.set_pixel(x, b, edge); img.set_pixel(x, s - 1 - b, edge)
			img.set_pixel(b, x, edge); img.set_pixel(s - 1 - b, x, edge)
	return ImageTexture.create_from_image(img)

## 发光框贴图：暖黄柔光实心（modulate 在 _process 里脉动）。
func _glow_texture() -> Texture2D:
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.92, 0.5, 0.6))
	return ImageTexture.create_from_image(img)
