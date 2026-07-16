extends SceneTree
## 位置流二进制编解码(必修②块B):客户端 PosCodec 自 round-trip + 与服务端黄金字节双向对拍。
## 黄金字节由 server/src/pos_codec.ts 对同一消息生成(见测试内注释),钉死字节序/布局跨语言一致。
## 运行: godot --headless --path . --script res://test/test_pos_codec.gd

func _init() -> void:
	var fails := 0

	# ── 自 round-trip:relay(x/y 取 float32 可精确表示值)──
	var relay_chars := [{ "id": "char-abc", "x": 12.5, "y": -3.25 }, { "id": "角色id", "x": 0.0, "y": 74.5 }]
	var relay_player := { "id": "player-xyz", "x": 37.0, "y": 37.75 }
	var relay_dec := PosCodec.decode_relay(PosCodec.encode_relay(1234567, "seafloor", relay_chars, relay_player))
	fails += _check("relay t", relay_dec.get("t"), 1234567)
	fails += _check("relay sceneId", relay_dec.get("sceneId"), "seafloor")
	fails += _check("relay chars 数", (relay_dec.get("chars") as Array).size(), 2)
	fails += _check("relay char0 id", relay_dec["chars"][0]["id"], "char-abc")
	fails += _check("relay char0 x", relay_dec["chars"][0]["x"], 12.5)
	fails += _check("relay char1 汉字 id", relay_dec["chars"][1]["id"], "角色id")
	fails += _check("relay player id", relay_dec["player"]["id"], "player-xyz")
	fails += _check("relay player y", relay_dec["player"]["y"], 37.75)

	# ── 自 round-trip:report(带 tile,含负 tile)──
	var rep_chars := [{ "id": "npc1", "x": 1.5, "y": 2.5, "tileX": 3, "tileY": 4 }, { "id": "npc2", "x": -10.25, "y": 5.0, "tileX": -1, "tileY": 74 }]
	var rep_player := { "x": 20.0, "y": 21.5, "tileX": 10, "tileY": 11 }
	var rep_dec := PosCodec.decode_report(PosCodec.encode_report("forest", 999, rep_chars, rep_player))
	fails += _check("report sceneId", rep_dec.get("sceneId"), "forest")
	fails += _check("report char1 负 tileX", rep_dec["chars"][1]["tileX"], -1)
	fails += _check("report char1 x", rep_dec["chars"][1]["x"], -10.25)
	fails += _check("report player tileY", rep_dec["player"]["tileY"], 11)

	# ── 空场景:relay 空 chars 无 player ──
	var empty := PosCodec.decode_relay(PosCodec.encode_relay(0, "village", [], {}))
	fails += _check("空 relay chars 空", (empty.get("chars") as Array).size(), 0)
	fails += _check("空 relay 无 player 键", empty.has("player"), false)

	# ── 跨语言黄金字节对拍(由 server/src/pos_codec.ts encodeRelay 生成)──
	# encodeRelay({t:1000000,sceneId:"village",chars:[{id:"c1",x:1.5,y:2.5}],player:{id:"p1",x:3.5,y:4.5}})
	var golden_relay := PackedByteArray([177,1,0,0,0,0,128,132,46,65,7,118,105,108,108,97,103,101,1,0,2,99,49,0,0,192,63,0,0,32,64,1,2,112,49,0,0,96,64,0,0,144,64])
	var gr := PosCodec.decode_relay(golden_relay)
	fails += _check("黄金 relay t", gr.get("t"), 1000000)
	fails += _check("黄金 relay sceneId", gr.get("sceneId"), "village")
	fails += _check("黄金 relay char0 id", gr["chars"][0]["id"], "c1")
	fails += _check("黄金 relay char0 x", gr["chars"][0]["x"], 1.5)
	fails += _check("黄金 relay char0 y", gr["chars"][0]["y"], 2.5)
	fails += _check("黄金 relay player id", gr["player"]["id"], "p1")
	fails += _check("黄金 relay player x", gr["player"]["x"], 3.5)

	# encodeReport({sceneId:"forest",t:2000000,chars:[{id:"n1",x:5.5,y:6.5,tileX:7,tileY:8}],player:{x:9.5,y:10.5,tileX:11,tileY:12}})
	var golden_report := PackedByteArray([178,1,6,102,111,114,101,115,116,0,0,0,0,128,132,62,65,1,0,2,110,49,0,0,176,64,0,0,208,64,7,0,8,0,1,0,0,24,65,0,0,40,65,11,0,12,0])
	var my_report := PosCodec.encode_report("forest", 2000000, [{ "id": "n1", "x": 5.5, "y": 6.5, "tileX": 7, "tileY": 8 }], { "x": 9.5, "y": 10.5, "tileX": 11, "tileY": 12 })
	fails += _check("客户端 encode_report == 服务端黄金字节", my_report, golden_report)

	if fails == 0:
		print("pos_codec tests PASS")
	else:
		printerr("pos_codec tests FAILED: %d" % fails)
	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got %s want %s" % [name, str(got), str(want)])
	return 1
