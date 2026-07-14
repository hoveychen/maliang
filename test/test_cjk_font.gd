extends SceneTree
## 中文字形兜底（iOS 豆腐块修复）：证明项目默认字体在「不依赖操作系统 CJK 回落」的前提下，
## 自带字形能覆盖 UI 中文与孩子名字用字。
##
## 为什么这样测：Android/macOS 上系统有 Noto CJK / PingFang，allow_system_fallback 能兜底，
## 中文正常——所以 bug 在这些平台不可见。iOS 上 Godot 的系统字体回落对 CJK 不稳，就渲染成
## 豆腐块（□□□）。本测试把整条字体链的 allow_system_fallback 关掉，复现 iOS「拿不到系统 CJK」
## 的处境：此时 has_char 只反映自带字形（本体 cmap + 显式 fallbacks），不看系统字体。
##   - 修复前：默认字体是 Godot 内置字体（无 CJK），关系统回落后 has_char("中")=false → 本测 RED。
##   - 修复后：默认字体=站酷快乐体（圆润童趣）+ 霞鹜文楷（全字形）兜底 → 全部命中 → GREEN。
## 其中「玥」这类站酷快乐体本体缺、须靠霞鹜文楷兜底的字，专门守住 fallback 接线没掉。
##
## 运行: godot --headless --path . --script res://test/test_cjk_font.gd

func _init() -> void:
	var fails := 0

	# 取 UI 真正用到的默认字体（Label 解析路径，等于 gui/theme/custom_font）
	var l := Label.new()
	get_root().add_child(l)
	var font: Font = l.get_theme_default_font()
	fails += _check("默认字体非空", font != null, true)

	# 复现 iOS：关掉整条字体链的系统回落，让 has_char 只认自带字形
	_disable_system_fallback(font)

	# 必须覆盖的 UI 中文
	var ui := "你好开始设置确认取消再见名字造物村民小仙子点点森林月亮风车草莓画质重新检测"
	fails += _assert_all_covered("UI 中文", font, ui)

	# 孩子名字常用字——含「玥」，站酷快乐体本体没有、靠霞鹜文楷兜底（守住 fallback 接线）
	var names := "萱睿煊翔玥曦懿骐骥梓涵欣妍浩宇轩"
	fails += _assert_all_covered("名字用字", font, names)

	# 拉丁字母与数字不能被搞坏（时钟等仍要能显示）
	var latin := "Hello World 2024 :"
	fails += _assert_all_covered("拉丁+数字", font, latin)

	# 明确守住「玥」这一条兜底链：站酷快乐体本体缺、整条链须命中
	fails += _check("玥（须靠霞鹜文楷兜底）", font.has_char("玥".unicode_at(0)), true)

	if fails == 0:
		print("cjk_font tests PASS")
	else:
		printerr("cjk_font tests FAILED: %d" % fails)
	quit(fails)

func _disable_system_fallback(f: Font) -> void:
	if f == null:
		return
	if f is FontFile:
		(f as FontFile).set_allow_system_fallback(false)
	elif f is FontVariation:
		var base := (f as FontVariation).base_font
		if base != null:
			_disable_system_fallback(base)
	for fb in f.get_fallbacks():
		_disable_system_fallback(fb)

func _assert_all_covered(label: String, f: Font, chars: String) -> int:
	var missing := ""
	for c in chars:
		if c == " ":
			continue
		if not f.has_char(c.unicode_at(0)):
			missing += c
	if missing.is_empty():
		return _check(label + " 全覆盖", true, true)
	printerr("  %s 缺字形（无系统回落）: %s" % [label, missing])
	return 1

func _check(name: String, got: Variant, want: Variant) -> int:
	if got == want:
		return 0
	printerr("  FAIL %s: got=%s want=%s" % [name, str(got), str(want)])
	return 1
