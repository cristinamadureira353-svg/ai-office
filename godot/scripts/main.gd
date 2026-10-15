extends Node2D
## 主入口。M1 阶段只做最小心跳：确认场景能跑、后续小节往这里挂东西。

const BACKEND := "http://127.0.0.1:8850"

func _ready() -> void:
	print("[MAIN] _ready 场景加载完成")
	print("[MAIN] 后端地址 ", BACKEND)
	print("[MAIN] viewport=", get_viewport_rect().size)
	# M4-1：启动 BGM + 办公室环境音。Audio 是 autoload 单例，
	# 这里只发启动指令，不持有播放器——切场景时音频不会断。
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("start"):
		audio.call("start")
