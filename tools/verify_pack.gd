extends SceneTree
## 内容包内容校验（content-pck-distribution P5）：挂载 build/packs/*.pck，断言关键资源/文件在包内。
## 用法：Godot --headless --path . --script tools/verify_pack.gd
## 退出码 = 失败断言数。

const CHECKS := {
	"city": {
		"res": ["res://assets/city/building-a.glb", "res://assets/city/building-skyscraper-e.glb"],
		"file": [],
	},
	"medieval_kingdom": {
		"res": ["res://assets/medieval/hexagon/building_castle_blue.gltf",
				"res://assets/medieval/builder/watchtower.glb"],
		"file": [],
	},
	"roman": {
		# glb + 外挂贴图（源 png 导入为 ctex，随 glb 依赖带入）——验证贴图确实在包里。
		"res": ["res://assets/roman/roman_wall.glb", "res://assets/roman/roman_arch.glb",
				"res://assets/roman/roman_wall_0.png"],
		"file": [],
	},
	"voice_story_hood": {
		"res": ["res://assets/voice/story_hood/hood_0_1.wav"],
		# lines.json 是非资源文件，走 include_filter 打进包——DirAccess/FileAccess 应可见。
		"file": ["res://assets/voice/story_hood/lines.json"],
	},
}

func _init() -> void:
	var fails := 0
	for name in CHECKS:
		var pck := "res://build/packs/%s.pck" % name
		if not FileAccess.file_exists(pck):
			print("MISS pck: %s" % pck)
			fails += 1
			continue
		if not ProjectSettings.load_resource_pack(pck, false):
			print("FAIL mount: %s" % pck)
			fails += 1
			continue
		for r in CHECKS[name]["res"]:
			if ResourceLoader.exists(r):
				print("  ok res  %s" % r)
			else:
				print("  FAIL res %s (not in %s)" % [r, name])
				fails += 1
		for f in CHECKS[name]["file"]:
			if FileAccess.file_exists(f):
				print("  ok file %s" % f)
			else:
				print("  FAIL file %s (not in %s)" % [f, name])
				fails += 1
	print("verify_pack: %d failures" % fails)
	quit(fails)
