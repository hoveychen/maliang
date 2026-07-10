extends SceneTree
## PaperCharacter X 光穿透 pass 档位开关单测：桌面默认开；set_xray_enabled(false)
## 摘除已存在与后续新建角色的 next_pass；重新启用全部恢复。
## 运行: godot --headless --path . --script res://test/test_paper_xray_gate.gd

func _initialize() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)

func _run() -> void:
	var fails := 0
	var a := PaperCharacter.new()
	root.add_child(a)
	fails += _check("desktop default on", a._mat.next_pass != null, true)
	PaperCharacter.set_xray_enabled(false, self)
	fails += _check("disable strips existing", a._mat.next_pass == null, true)
	var b := PaperCharacter.new()
	root.add_child(b)
	fails += _check("disable applies to new", b._mat.next_pass == null, true)
	PaperCharacter.set_xray_enabled(true, self)
	fails += _check("re-enable restores existing", a._mat.next_pass != null, true)
	fails += _check("re-enable restores new", b._mat.next_pass != null, true)
	if fails == 0:
		print("paper_xray_gate tests PASS (5/5)")
	else:
		printerr("paper_xray_gate tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
