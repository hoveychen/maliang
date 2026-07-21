extends SceneTree
## 新玩家出生锚点（s1-hood-polish P1）：新玩家必须落在村庄核心出生角（近原点、z<40），
## 绝不能跟着点点的服务端种子位生进森林带（village_forest 村北 z>40）。
## 返程玩家的存档位走 _restore_player_pos，不经此函数——这里只钉「新玩家默认」。
## world.gd 的 _new_player_spawn_anchor 只用 WorldGrid 静态 + 入参，可对裸实例调用（不入树）。
## 运行: godot --headless --path . --script res://test/test_spawn_anchor.gd

const HOME_TILE := Vector2i.ZERO

var _fails := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	WorldGrid.configure(100) # village_forest 是 100 格场景
	var world_script := load("res://scripts/world.gd")
	var w: Node = world_script.new() # 不 add_child：_ready 不跑，纯函数不依赖实例状态

	# 点点种子在村北森林带（z>40，例：seed (28,52) 或 WORLD_CENTER (50,50)）
	var forest_a := WorldGrid.from_tile_center(Vector2i(28, 52))
	var forest_b := WorldGrid.from_tile_center(Vector2i(50, 50))
	var anchor_a: Vector2 = w.call("_new_player_spawn_anchor", forest_a)
	var anchor_b: Vector2 = w.call("_new_player_spawn_anchor", forest_b)
	var tile_a := WorldGrid.to_tile(anchor_a)
	var tile_b := WorldGrid.to_tile(anchor_b)

	# 核心断言：无论点点种子在森林哪里，新玩家锚点都落村庄核心（z<40）
	_check("点点种子(28,52)在森林→新玩家锚仍在村核 z<40", tile_a.y < 40, true)
	_check("点点种子(50,50)在森林→新玩家锚仍在村核 z<40", tile_b.y < 40, true)
	# 锚点不再依赖点点位置：两个不同种子位给出同一锚点
	_check("出生锚点不随点点种子漂移（同一村核锚）", tile_a, tile_b)
	# 精确落在设计的出生角原点
	_check("新玩家锚点=出生角原点(0,0)", tile_a, HOME_TILE)

	w.free()
	quit(_fails)

func _check(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		print("  ok ", name)
	else:
		printerr("  FAIL ", name, " got=", got, " want=", want)
		_fails += 1
