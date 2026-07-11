extends SceneTree
## TerrainAtlas 程序生成纹理的独立测试（只测 Image，不碰 RenderingServer）。
## 运行: godot --headless --path . --script res://test/test_terrain_atlas.gd
## 可选: 环境变量 ATLAS_DUMP=/abs/path.png 落盘目检。

func _init() -> void:
	var fails := 0
	var img := TerrainAtlas.build_image()

	fails += _check("width", img.get_width(), TerrainAtlas.W)
	fails += _check("height", img.get_height(), TerrainAtlas.H)

	# 控制图格式：RGBA（R 主体域 / G 描边 / B 类型÷8 / A 明暗×0.5）
	fails += _check("format rgba8", img.get_format(), Image.FORMAT_RGBA8)

	# 像素探针：cell 内容区中心/边角的控制值符合语义
	var g := _probe(img, TerrainMap.T_GRASS, Autotile.C_NW, 0, 16.0, 16.0)
	fails += _check("grass base (R=0,B=0)", 1 if (g.r < 0.05 and g.b < 0.05) else 0, 1)
	fails += _check("grass lum sane", 1 if (g.a > 0.4 and g.a < 0.6) else 0, 1)
	# 棋盘 parity：暗格 cell 的基础明暗低于亮格（三角纹外的同一像素点位）
	var ga := _probe_at(img, TerrainMap.T_GRASS, 0, 8.0, 4.0)
	var gb := _probe_at(img, TerrainMap.T_GRASS, 1, 8.0, 4.0)
	fails += _check("grass parity shade", 1 if gb.a < ga.a else 0, 1)

	var p := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
	fails += _check("path body (R=1,B=1/8)", 1 if (p.r > 0.95 and _btype(p) == TerrainMap.T_PATH) else 0, 1)

	var w := _probe(img, TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
	fails += _check("bed body (R=1,B=2/8)", 1 if (w.r > 0.95 and _btype(w) == TerrainMap.T_WATER) else 0, 1)
	fails += _check("full water no foam", 1 if w.g < 0.05 else 0, 1)
	# 水 cell 的 R/B/A 全 cell 都是湖床主体；G 只在贴岸带出泡沫（水面 mesh 采样用）
	var wedge := _probe(img, TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_EDGE_H, 16.0, TerrainAtlas.MARGIN + 1.5)
	fails += _check("bed body under foam band", 1 if (wedge.r > 0.95 and wedge.g > 0.9) else 0, 1)
	var wmid := _probe(img, TerrainMap.T_WATER, Autotile.C_NW, Autotile.V_EDGE_H, 16.0, 24.0)
	fails += _check("foam fades off shore", 1 if wmid.g < 0.05 else 0, 1)

	# OUTER 变体：NW 角外缘应是草，内里是路
	var oc := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_OUTER, 1.0, 1.0)
	fails += _check("outer corner grass", 1 if oc.r < 0.05 else 0, 1)
	var oi := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_OUTER, 28.0, 28.0)
	fails += _check("outer inner path", 1 if (oi.r > 0.95 and _btype(oi) == TerrainMap.T_PATH) else 0, 1)
	# SE 角镜像：外缘在右下
	var se := _probe(img, TerrainMap.T_PATH, Autotile.C_SE, Autotile.V_OUTER, 31.0, 31.0)
	fails += _check("se mirrored grass", 1 if se.r < 0.05 else 0, 1)

	# EDGE_V：紧贴边距处是描边（G=1）
	var rim := _probe(img, TerrainMap.T_PATH, Autotile.C_NW, Autotile.V_EDGE_V, TerrainAtlas.MARGIN + 1.5, 16.0)
	fails += _check("edge rim mask", 1 if rim.g > 0.95 else 0, 1)

	# 悬崖边草皮：外缘是崖唇主体（B=3/8），内里是草（R=0 但 B 仍恒 3/8——线性过滤安全）
	var lip := _probe(img, TerrainAtlas.CLIFF_RIM, Autotile.C_NW, Autotile.V_EDGE_H, 16.0, 1.0)
	fails += _check("cliff lip body", 1 if (lip.r > 0.95 and _btype(lip) == TerrainAtlas.CLIFF_RIM) else 0, 1)
	var top := _probe(img, TerrainAtlas.CLIFF_RIM, Autotile.C_NW, Autotile.V_EDGE_H, 16.0, 24.0)
	fails += _check("cliff top grass", 1 if (top.r < 0.05 and _btype(top) == TerrainAtlas.CLIFF_RIM) else 0, 1)
	var wallc := _probe(img, TerrainAtlas.CLIFF_WALL, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
	fails += _check("wall body", 1 if (wallc.r > 0.95 and _btype(wallc) == TerrainAtlas.CLIFF_WALL) else 0, 1)
	# 墙格无邻墙侧（EDGE_V 外缘）是凹缝暗边，明暗比主体明显更低
	var crev := _probe(img, TerrainAtlas.CLIFF_WALL, Autotile.C_NW, Autotile.V_EDGE_V, 1.0, 16.0)
	fails += _check("wall crevice dark", 1 if crev.a < wallc.a * 0.85 else 0, 1)

	# 新增可行走地表（world-themes P1）：整格 V_FULL 铺满 body（R=1, B=type/8），无描边（G=0），
	# OUTER 角外缘是草——验证 _body_fn + uv_rect BODY_ROWS 路由 + B 通道对齐 shader ty。
	for nt in [TerrainMap.T_SAND, TerrainMap.T_SNOW, TerrainMap.T_TILE]:
		var full := _probe(img, nt, Autotile.C_NW, Autotile.V_FULL, 16.0, 16.0)
		fails += _check("body full R=1 (ty=%d)" % nt, 1 if full.r > 0.95 else 0, 1)
		fails += _check("body full B=ty (ty=%d)" % nt, _btype(full), nt)
		fails += _check("body full no rim (ty=%d)" % nt, 1 if full.g < 0.05 else 0, 1)
		var out_g := _probe(img, nt, Autotile.C_NW, Autotile.V_OUTER, 1.0, 1.0)
		fails += _check("body outer grass (ty=%d)" % nt, 1 if out_g.r < 0.05 else 0, 1)
		var out_i := _probe(img, nt, Autotile.C_NW, Autotile.V_OUTER, 28.0, 28.0)
		fails += _check("body outer inner=body (ty=%d)" % nt, 1 if (out_i.r > 0.95 and _btype(out_i) == nt) else 0, 1)

	# uv_rect 都在 [0,1] 且互不重叠（抽查全组合的中心点唯一性）
	var centers := {}
	var overlap := 0
	for ty in [TerrainMap.T_PATH, TerrainMap.T_WATER, TerrainAtlas.CLIFF_RIM, TerrainAtlas.CLIFF_WALL,
			TerrainMap.T_SAND, TerrainMap.T_SNOW, TerrainMap.T_TILE]:
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

## 取 (类型,角,变体) cell 内容坐标 (cx,cy) px 处的控制值。
func _probe(img: Image, type: int, corner: int, variant: int, cx: float, cy: float) -> Color:
	return _probe_at(img, type, 0, cx, cy) if type == TerrainMap.T_GRASS \
		else _probe_rect(img, TerrainAtlas.uv_rect(type, corner, variant, 0), cx, cy)

## 草地 cell 按 parity 探针（草行的列 = parity）。
func _probe_at(img: Image, type: int, parity: int, cx: float, cy: float) -> Color:
	return _probe_rect(img, TerrainAtlas.uv_rect(type, 0, 0, parity), cx, cy)

func _probe_rect(img: Image, r: Rect2, cx: float, cy: float) -> Color:
	var px := int(r.position.x * TerrainAtlas.W + cx)
	var py := int(r.position.y * TerrainAtlas.H + cy)
	return img.get_pixel(px, py)

## B 通道 → 主体类型码。
func _btype(c: Color) -> int:
	return int(round(c.b * 8.0))

func _check(name: String, got: int, want: int) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %d want %d" % [name, got, want])
	return 1
