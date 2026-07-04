@tool
extends EditorExportPlugin
## Android 导出时把端侧 ASR 的两个 AAR 打进 APK：
## - maliang-asr-plugin.aar：本插件（scripts/build-asr-plugin.sh 构建，模型已打进其 assets/）
## - sherpa-onnx-*.aar：推理引擎（同脚本下载）
## 模型文件随插件 AAR 的 assets 一起被 AGP 合并进 APK assets，无需单独注入。

const BIN := "maliang_asr/bin"

func _get_name() -> String:
	return "MaliangAsr"

func _supports_platform(platform: EditorExportPlatform) -> bool:
	return platform is EditorExportPlatformAndroid

func _get_android_libraries(_platform: EditorExportPlatform, _debug: bool) -> PackedStringArray:
	var missing: PackedStringArray = []
	for f in ["%s/maliang-asr-plugin.aar" % BIN, "%s/sherpa-onnx-1.13.3.aar" % BIN]:
		if not FileAccess.file_exists("res://addons/" + f):
			missing.append(f)
	if not missing.is_empty():
		push_warning("MaliangAsr：缺少 %s，先跑 scripts/build-asr-plugin.sh；本次导出不含端侧 ASR（运行时自动回落服务端识别）" % ", ".join(missing))
		return PackedStringArray()
	return PackedStringArray(["%s/maliang-asr-plugin.aar" % BIN, "%s/sherpa-onnx-1.13.3.aar" % BIN])
