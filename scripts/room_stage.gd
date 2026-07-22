class_name RoomStage
extends Node3D
## 室内房间舞台（home-interior 重做）：一间有界的屋子，不是地形。
##
## 初版把室内塞进无限连续 chunk 地形（抬地形块假装墙、掏实心躲露地）被否决——地形系统是给
## 无限滚动室外的，室内要的是有界舞台。本节点给室内做正经几何：木地板 + 三面墙（壁纸）+ 踢脚线，
## 相机从开着的前墙（+z 朝相机那面不建）俯看进屋，对齐动物森友会/Pokopia 室内观感。
##
## 坐标系：房间以本节点局部原点为中心（地板中心 = (0,0,0)）。渲染分支（world.gd）把 focus 钉在
## 房间中心、本节点摆在渲染原点，故玩家/家具按「相对房间中心」的最短环面位移落到房间格上。
##
## 天花板不做真 mesh——俯视 3/4 相机下实心顶会挡住整屋。暗顶靠 world.gd 的 INDOOR_BG_COLOR 收顶
## （墙升到暗背景里，相机从墙上方俯看）。真天花板（模拟人生式近侧剖切）属后续增强。
##
## 材质复用地形贴图：地板 wood_floor.png、墙面 toy_wall.png（点点墙纸）——与旧地形-hack 同一套。

const TILE := 2.0                 ## = WorldGrid.TILE_SIZE（房间格边长，米）
const WALL_H := 4.5               ## 墙高（米）——够挡住相机看到墙外暗背景；俯角/距离在 P3 眼验微调
const WALL_THICK := 0.3           ## 墙体厚度（米）：薄盒给墙一点实体感，内壁贴壁纸
const BASE_H := 0.35              ## 踢脚线高度（米）
const BASE_THICK := 0.06          ## 踢脚线凸出墙面的厚度（米）
const FLOOR_TEX := "res://assets/textures/terrain/wood_floor.png"
const WALL_TEX := "res://assets/textures/terrain/toy_wall.png"
const BASE_COLOR := Color(0.32, 0.24, 0.20)  ## 踢脚线暖木深色

var _room_n := 0                  ## 当前房间边长（tile 数）；0 = 未构建

## 构建 n×n tile 的房间（地板 + 后/左/右三面墙 + 踢脚线；前墙不建、暗顶不建）。
## 幂等：同尺寸重复调用先 clear 再建。n<=0 视作 clear。
func build(n: int) -> void:
	clear()
	if n <= 0:
		return
	_room_n = n
	var span := float(n) * TILE          # 房间边长（米）
	var half := span * 0.5

	# ── 地板：PlaneMesh，木地板贴图按 tile 平铺 ──────────────────────────────
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	var pm := PlaneMesh.new()
	pm.size = Vector2(span, span)        # PlaneMesh 默认朝 +y，居中于原点
	floor_mi.mesh = pm
	floor_mi.material_override = _floor_material(n)
	add_child(floor_mi)

	# ── 三面墙（后 -z / 左 -x / 右 +x）；前墙 +z（朝相机）不建 ──────────────
	# 薄盒墙：中心抬到 WALL_H/2；墙盒沿墙延伸方向比净空各多伸半个墙厚，补上四角接缝。
	var wall_mat := _wall_material(n)
	_add_wall("WallBack", Vector3(span + WALL_THICK, WALL_H, WALL_THICK),
		Vector3(0.0, WALL_H * 0.5, -half - WALL_THICK * 0.5), wall_mat)
	_add_wall("WallLeft", Vector3(WALL_THICK, WALL_H, span + WALL_THICK),
		Vector3(-half - WALL_THICK * 0.5, WALL_H * 0.5, 0.0), wall_mat)
	_add_wall("WallRight", Vector3(WALL_THICK, WALL_H, span + WALL_THICK),
		Vector3(half + WALL_THICK * 0.5, WALL_H * 0.5, 0.0), wall_mat)

	# ── 踢脚线：三面墙内壁底部一圈深木条 ───────────────────────────────────
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = BASE_COLOR
	base_mat.roughness = 0.9
	_add_wall("BaseBack", Vector3(span, BASE_H, BASE_THICK),
		Vector3(0.0, BASE_H * 0.5, -half + BASE_THICK * 0.5), base_mat)
	_add_wall("BaseLeft", Vector3(BASE_THICK, BASE_H, span),
		Vector3(-half + BASE_THICK * 0.5, BASE_H * 0.5, 0.0), base_mat)
	_add_wall("BaseRight", Vector3(BASE_THICK, BASE_H, span),
		Vector3(half - BASE_THICK * 0.5, BASE_H * 0.5, 0.0), base_mat)

## 拆掉整间屋（出室内/重建前调用）。同步 free（非 queue_free）：build 同帧内先 clear 再重建，
## 延迟释放会让旧墙叠在新墙上（同帧还没销毁）。都是叶子 MeshInstance3D，即时释放安全。
func clear() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	_room_n = 0

## 当前房间边长（tile 数），未构建为 0。
func room_n() -> int:
	return _room_n

func _add_wall(node_name: String, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	mi.material_override = mat
	add_child(mi)

## 地板材质：木地板贴图按房间 tile 数平铺（一张贴图 = 一格）。
func _floor_material(n: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var tex: Texture2D = load(FLOOR_TEX)
	if tex != null:
		m.albedo_texture = tex
		m.uv1_scale = Vector3(float(n), float(n), 1.0)
	m.roughness = 0.85
	m.metallic = 0.0
	return m

## 墙面材质：点点墙纸按 tile 平铺（横向 n 格、竖向按墙高折算）。
func _wall_material(n: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var tex: Texture2D = load(WALL_TEX)
	if tex != null:
		m.albedo_texture = tex
		m.uv1_scale = Vector3(float(n), maxf(1.0, round(WALL_H / TILE)), 1.0)
	m.roughness = 0.9
	m.metallic = 0.0
	return m
