extends SceneTree
## 签名 app 内的「扩展加载」直接检查：同步、只在 _initialize 里写文件后立即退出，
## 不调 initialize()、不等异步信号（导出 release app 的 --script 不驱动 _process）。
## 证明 hardened runtime + disable-library-validation 下 GDExtension 及其 sherpa dylib 能被 dlopen。
## MALIANG_ASR_CHECK_OUT=<abs> 指定输出文件。
func _initialize() -> void:
	var out := OS.get_environment("MALIANG_ASR_CHECK_OUT")
	var lines := PackedStringArray()
	var has := Engine.has_singleton("MaliangAsr")
	lines.append("has_singleton=%s" % has)
	if has:
		var a := Engine.get_singleton("MaliangAsr")
		lines.append("has_initialize=%s" % a.has_method("initialize"))
		lines.append("has_feedPcm=%s" % a.has_method("feedPcm"))
		lines.append("has_stopSession=%s" % a.has_method("stopSession"))
		lines.append("is_ready_before_init=%s" % a.is_ready())
		# 内置模型是否随包就位（C++ 解析的 Contents/Resources 路径）
		var exe_dir := OS.get_executable_path().get_base_dir()
		var bundled := exe_dir.path_join("../Resources/asr-models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12").simplify_path()
		lines.append("bundled_tokens_exists=%s" % FileAccess.file_exists(bundled.path_join("tokens.txt")))
	if not out.is_empty():
		var f := FileAccess.open(out, FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(lines)); f.flush(); f.close()
	quit(0 if has else 1)
