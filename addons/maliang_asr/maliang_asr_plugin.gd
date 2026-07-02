@tool
extends EditorPlugin
## MaliangAsr 编辑器插件：仅负责注册 Android 导出钩子（AAR 注入）。

var _export_plugin: EditorExportPlugin

func _enter_tree() -> void:
	_export_plugin = preload("res://addons/maliang_asr/export_plugin.gd").new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null
