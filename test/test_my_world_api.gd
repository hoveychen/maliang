extends SceneTree
## 每人一世界端点契约（世界模板架构 v2 P3）：api.my_world_path 拼对端点 + 查询串 + 编码。
## 客户端不再写死 default，改用 GET /worlds/mine?playerId=<设备 UUID> 拿 w_<playerId>（服务端从
## template 复制放置）。这里只断言纯函数拼路径（不起真网）；离线不回归由整套 headless 冒烟保证。
## 运行: godot --headless --path . --script res://test/test_my_world_api.gd

func _init() -> void:
	var fails := 0

	# 端点 + 查询串：设备玩家 id 是 hex UUID（无特殊字符），原样拼
	fails += _check("端点+查询串", Api.my_world_path("abc123"), "/worlds/mine?playerId=abc123")

	# 特殊字符必须 uri_encode（防破串/注入），与 String.uri_encode 一致
	fails += _check("特殊字符编码", Api.my_world_path("a b&c"), "/worlds/mine?playerId=" + "a b&c".uri_encode())

	# 去写死 default：路径里不该再出现 default 字样
	fails += _check("不含 default", Api.my_world_path("x").contains("default"), false)

	# 走 /worlds/mine（静态段），不撞 /worlds/:id 参数段
	fails += _check("命中 mine 端点", Api.my_world_path("x").begins_with("/worlds/mine?"), true)

	quit(fails)

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		print("  ok ", name)
		return 0
	printerr("  FAIL ", name, " got=", got, " want=", want)
	return 1
