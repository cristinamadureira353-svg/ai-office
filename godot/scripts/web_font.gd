extends Node
## 网页没有 macOS 的系统字体，随包字体保证中文状态与聊天可读。
func _enter_tree() -> void:
	if OS.has_feature("web"):
		ThemeDB.fallback_font = load("res://assets/fonts/NotoSansCJKsc-Regular.otf")
