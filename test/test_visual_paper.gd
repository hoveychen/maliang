extends SceneTree
## 纸片角色演出回归：
## (1) 结构——PaperCharacter 是细分 QuadMesh + paper_character shader（单面片弯不了，
##     细分是卷曲/飘动的前提）；
## (2) 走路——向左移动后 walk 强度拉起、下摆飘动(flutter_amp)非零、完成翻面(ry≈PI，
##     立绘统一朝右，镜像即朝左)；
## (3) 转身——换向右移的中途 ry 处在中间角（侧对相机的「纸边」瞬间真实发生过）；
## (4) 待机——停步后 walk/flutter 归零、呼吸微卷(curl)仍在起伏（角色不死板）。
## 运行: MALIANG_API_BASE=http://127.0.0.1:1 godot --headless --fixed-fps 10 \
##       --quit-after 100 --script res://test/test_visual_paper.gd
## 退出码 = 失败断言数（同 scripts/test-headless.sh 约定）。

var scene: Node
var frame := 0
var fails := 0
var _mid_flip_seen := false ## 换向期间任一帧 ry 落在中间角
var _idle_curl_max := 0.0   ## 待机期间 |curl| 峰值
var _sway_max := 0.0        ## 走路期间 |rotation.z| 峰值（相位随机，单帧抽样会撞 sin≈0 误报）

func _initialize() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	process_frame.connect(_tick)

func _tick() -> void:
	if scene == null:
		return
	frame += 1
	var player: Dictionary = scene.get("player")
	if player.is_empty():
		return
	var node: PaperCharacter = player["node"]
	match true:
		_ when frame == 10:
			_structural(node)
		_ when frame > 10 and frame <= 30:
			_drive(player, Vector2(-0.8, 0.0)) # 向左走 2s（8m/s @ 10fps）
			# 摇摆相位 randf()*TAU 起步：单帧抽样会偶发撞上 sin≈0（实测全套 ~0.6%/次误报），
			# 改走路期间累计峰值，f31 一并断言
			_sway_max = maxf(_sway_max, absf(node.rotation.z))
		_ when frame == 31:
			_check("走路强度拉起 (paper_walk)", float(player.get("paper_walk", 0.0)) > 0.5, true)
			_check("走路下摆飘动非零 (flutter_amp)", _param(node, "flutter_amp") > 0.03, true)
			_check("向左移动完成翻面 (ry≈PI)", absf(node.rotation.y - PI) < 0.1, true)
			_check("走路左右摇摆在动 (max|rotation.z|)", _sway_max > 0.001, true)
		_ when frame > 31 and frame <= 45:
			_drive(player, Vector2(0.8, 0.0)) # 换向右走：翻面回 0，中途必过侧身
			var ry := node.rotation.y
			if ry > 0.2 and ry < PI - 0.2:
				_mid_flip_seen = true
		_ when frame == 46:
			_check("换向中途出现侧身纸边 (mid-flip)", _mid_flip_seen, true)
			_check("向右移动翻回正面 (ry≈0)", absf(node.rotation.y) < 0.1, true)
		_ when frame > 46 and frame <= 90:
			_idle_curl_max = maxf(_idle_curl_max, absf(_param(node, "curl"))) # 静止观察呼吸
		_ when frame == 91:
			_check("停步后走路强度归零", float(player.get("paper_walk", 1.0)) < 0.15, true)
			_check("停步后飘动归零", _param(node, "flutter_amp") < 0.02, true)
			_check("待机呼吸微卷仍在起伏 (curl 峰值)", _idle_curl_max > 0.01, true)
			_finish()

func _structural(node: PaperCharacter) -> void:
	_check("角色是 MeshInstance3D（细分网格，非 Sprite3D 单面片）", node is MeshInstance3D, true)
	var q := node.mesh as QuadMesh
	_check("网格是 QuadMesh", q != null, true)
	if q != null:
		_check("宽向已细分（卷曲前提）", q.subdivide_width > 0, true)
		_check("高向已细分（飘动前提）", q.subdivide_depth > 0, true)
	var mat := node.material_override as ShaderMaterial
	_check("挂 paper_character shader", mat != null and mat.shader.resource_path == "res://shaders/paper_character.gdshader", true)
	_check("贴图已进 shader (albedo_tex)", mat != null and mat.get_shader_parameter("albedo_tex") != null, true)

## 直接推逻辑坐标模拟移动（只测渲染演出，绕过 Mover 地形/占用规则）。
func _drive(player: Dictionary, step: Vector2) -> void:
	player["logical"] = WorldGrid.wrap_pos(player["logical"] + step)

func _param(node: PaperCharacter, pname: String) -> float:
	var mat := node.material_override as ShaderMaterial
	if mat == null:
		return 0.0
	var v: Variant = mat.get_shader_parameter(pname)
	return float(v) if v != null else 0.0

func _finish() -> void:
	if fails == 0:
		print("visual_paper PASS")
	else:
		printerr("visual_paper FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok %s" % name)
		return
	fails += 1
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
