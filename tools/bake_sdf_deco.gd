extends SceneTree
## 构建期烘焙：SDF 布景 spec → 顶点吸附/顶点色 ArrayMesh 落盘 .res。
## 改过 spec 或 SdfStaticBaker 后重跑一次并提交产物：
##   godot --headless --quit-after 10 --script res://tools/bake_sdf_deco.gd
## 输出 assets/sdf_props/baked/<name>.res。
##
## 策略（老板定策）：静态 SDF 布景一律**构建期预烘焙、不在 runtime 里烘**。本工具扫描
## assets/sdf_props/ 下全部 spec，逐个判 SdfSpec.is_static——**静态**（loco=none∧无 spin/head/ropes）
## 才烘；**会动**的（走路小屋/蹦跳信箱/纸风车/点头花/传送门等）跳过、运行时照旧走 live SdfProp。
## 烘出的 .res 一旦存在，chunk_manager._spawn_static_sdf 就自动优先加载它、跳过 raymarch +
## 运行时 bake_and_swap。新增静态 prop 无需改本文件，重跑即自动纳入。

const SRC_DIR := "res://assets/sdf_props"
const OUT_DIR := "res://assets/sdf_props/baked"

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var fails := 0
	var baked := 0
	var skipped: Array[String] = []
	var da := DirAccess.open(SRC_DIR)
	if da == null:
		printerr("打不开 %s" % SRC_DIR)
		quit(1)
		return
	var names := da.get_files()
	names.sort()
	for fname in names:
		if not fname.ends_with(".json"):
			continue
		var path := "%s/%s" % [SRC_DIR, fname]
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (data is Dictionary):
			printerr("JSON 解析失败: %s" % path)
			fails += 1
			continue
		var cfg := SdfSpec.parse(data)
		if not cfg.ok:
			printerr("spec 不合法 %s: %s" % [path, cfg.error])
			fails += 1
			continue
		if not SdfSpec.is_static(cfg):
			skipped.append(fname.get_basename())  # 会动的 prop：runtime 走 live，不烘
			continue
		var t0 := Time.get_ticks_msec()
		var mesh := SdfStaticBaker.bake_config(cfg)
		if mesh == null:
			printerr("烘焙失败: %s" % path)
			fails += 1
			continue
		var out := "%s/%s.res" % [OUT_DIR, fname.get_basename()]
		var err := ResourceSaver.save(mesh, out)
		if err != OK:
			printerr("保存失败 %s: %s" % [out, error_string(err)])
			fails += 1
			continue
		baked += 1
		print("烘焙 %s → %s (%d 顶点, %dms)" % [fname, out,
			mesh.surface_get_array_len(0), Time.get_ticks_msec() - t0])
	print("完成：烘焙 %d 个静态 prop，跳过 %d 个会动 prop [%s]，失败 %d。" % [
		baked, skipped.size(), ", ".join(skipped), fails])
	quit(fails)
