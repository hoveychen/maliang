extends SceneTree
## 角色实时阴影开关(world.CHARACTER_SHADOWS)配套：BlobShadow.suppress_actor_blob 开时，
## 落地角色(bend=false)脚下暗斑让位给真实定向投影、不再挂 BlobShadow；SdfProp(bend=true)
## 不投实时阴影，脚下 blob 仍保留。避免"真实投影 + 脚下暗斑"双影。
## 运行: godot --headless --quit-after 20 --script res://test/test_actor_shadow.gd

var fails := 0

func _initialize() -> void:
	_test_suppress_actor_blob()
	if fails == 0:
		print("actor_shadow tests PASS")
	else:
		printerr("actor_shadow FAILED: %d" % fails)
	quit(fails)

func _check(what: String, got: Variant, want: Variant) -> void:
	if got != want:
		printerr("  FAIL %s: got %s want %s" % [what, got, want])
		fails += 1

func _test_suppress_actor_blob() -> void:
	# 关（默认全场景平光）：落地角色与 SdfProp 都挂脚下暗斑
	BlobShadow.suppress_actor_blob = false
	var a := Node3D.new()
	BlobShadow.attach(a, 0.5, false)
	_check("关闭时：落地角色有脚下暗斑", a.get_node_or_null("BlobShadow") != null, true)

	# 开（只角色投实时阴影）：落地角色让位、SdfProp 仍保留
	BlobShadow.suppress_actor_blob = true
	var b := Node3D.new()
	BlobShadow.attach(b, 0.5, false)
	_check("开启时：落地角色不再挂暗斑（避免双影）", b.get_node_or_null("BlobShadow"), null)
	var c := Node3D.new()
	BlobShadow.attach(c, 0.5, true)
	_check("开启时：SdfProp(bend) 仍保留脚下暗斑", c.get_node_or_null("BlobShadow") != null, true)

	BlobShadow.suppress_actor_blob = false  # 复位（static，防污染同进程其它逻辑）
	a.free()
	b.free()
	c.free()
