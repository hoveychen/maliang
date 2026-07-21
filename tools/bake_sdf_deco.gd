extends SceneTree
## 构建期烘焙：SDF 布景 spec → 顶点吸附/顶点色 ArrayMesh 落盘 .res。
## 改过 spec 或 SdfStaticBaker 后重跑一次并提交产物：
##   godot --headless --quit-after 10 --script res://tools/bake_sdf_deco.gd
## 输出 assets/sdf_props/baked/<name>.res（chunk_manager preload）。

const SPECS := [
	"res://assets/sdf_props/tree_puff_a.json",
	"res://assets/sdf_props/tree_puff_b.json",
	"res://assets/sdf_props/tree_puff_c.json",
	"res://assets/sdf_props/bush_puff.json",
	# 绿野仙踪静态布景 prop（禁 runtime 惰烘，资产期预烘一次；chunk_manager._spawn_static_sdf 命中 .res 直接上静态实例）
	"res://assets/sdf_props/corn_stalk.json",
	"res://assets/sdf_props/emerald_castle.json",
]

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://assets/sdf_props/baked")
	var fails := 0
	for path in SPECS:
		var t0 := Time.get_ticks_msec()
		var mesh := SdfStaticBaker.bake_json_file(path)
		if mesh == null:
			printerr("烘焙失败: %s" % path)
			fails += 1
			continue
		var out := "res://assets/sdf_props/baked/%s.res" % path.get_file().get_basename()
		var err := ResourceSaver.save(mesh, out)
		if err != OK:
			printerr("保存失败 %s: %s" % [out, error_string(err)])
			fails += 1
			continue
		print("%s → %s (%d 顶点, %dms)" % [path.get_file(), out,
			mesh.surface_get_array_len(0), Time.get_ticks_msec() - t0])
	quit(fails)
