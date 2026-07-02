extends SceneTree
## TerrainAtlas 程序生成纹理的独立测试（只测 Image，不碰 RenderingServer）。
## 运行: godot --headless --path . --script res://test/test_terrain_atlas.gd
## 可选: 环境变量 ATLAS_DUMP=/abs/path.png 落盘目检。

func _init() -> void:
	var fails := 0
	var img := TerrainAtlas.build_image()

	fails += _check("width", img.get_width(), TerrainAtlas.W)
	fails += _check("height", img.get_height(), TerrainAtlas.H)

	# 像素探针：cell 内容区中心/边角的颜色符合语义
	var g := _probe(img, TerrainMap.T_GRASS, Autotile.C_NW, 0, 16.0, 16.0)
	fails += _check("grass is green", 1 if (g.g > g.r and g.g > g.b) else 0, 1)

	var p := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
	fails += _check("path is tan", 1 if (p.r > p.b and p.r > 0.7) else 0, 1)

	var w := _probe(img, TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
	fails += _check("water is blue", 1 if (w.b > w.r and w.b > 0.6) else 0, 1)

	# OUTER 变体：NW 角外缘应是草，内里是路
	var oc := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_OUTER, 1.0, 1.0)
	fails += _check("outer corner grass", 1 if (oc.g > oc.r) else 0, 1)
	var oi := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_OUTER, 28.0, 28.0)
	fails += _check("outer inner path", 1 if (oi.r > oi.b and oi.r > 0.7) else 0, 1)
	# SE 角镜像：外缘在右下
	var se := _probe(img, TerrainMap.T_PATH, Autotile.C_SE, Autotile.V_OUTER, 31.0, 31.0)
	fails += _check("se mirrored grass", 1 if (se.g > se.r) else 0, 1)

	# EDGE_V：紧贴边距处是描边亮色
	var rim := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_EDGE_V, TerrainAtlas.MARGIN + 1.5, 16.0)
	fails += _check("edge rim bright", 1 if rim.r > 0.9 else 0, 1)

	# 水岸描边接近白
	var foam := _probe(img, TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_EDGE_H, 16.0, TerrainAtlas.MARGIN + 1.5)
	fails += _check("water foam white", 1 if (foam.r > 0.85 and foam.b > 0.9) else 0, 1)

	# uv_rect 都在 [0,1] 且互不重叠（抽查全组合的中心点唯一性）
	var centers := {}
	var overlap := 0
	for ty in [TerrainMap.T_PATH, TerrainMap.T_WATER]:
		for c in range(4):
			for v in range(Autotile.VARIANT_COUNT):
				var r := TerrainAtlas.uv_rect(ty, c, v, 0)
				if r.position.x < 0.0 or r.position.y < 0.0 or r.end.x > 1.0 or r.end.y > 1.0:
					overlap += 1
				var key := r.get_center()
				if centers.has(key):
					overlap += 1
				centers[key] = true
	fails += _check("uv rects unique in range", overlap, 0)

	var dump := OS.get_environment("ATLAS_DUMP")
	if dump != "":
		img.save_png(dump)
		print("atlas dumped to ", dump)

	if fails == 0:
		print("terrain_atlas tests PASS")
	else:
		printerr("terrain_atlas tests FAILED: %d" % fails)
	quit(fails)

## 取 (类型,角,变体) cell 内容坐标 (cx,cy) px 处的颜色。
func _probe(img: Image, type: int, corner: int, variant: int, cx: float, cy: float) -> Color:
	var r := TerrainAtlas.uv_rect(type, corner, variant, 0)
	var px := int(r.position.x * TerrainAtlas.W + cx)
	var py := int(r.position.y * TerrainAtlas.H + cy)
	return img.get_pixel(px, py)

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
