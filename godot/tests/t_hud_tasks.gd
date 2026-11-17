extends SceneTree
## 「指令与待办」的可见窗口。
##
## 这里守两件事：
##   1. 不再有硬编码的 5 行上限——面板能放几行就放几行；
##   2. 条目比可见行多时，滚到底能看到最后一条（也就是全部条目都可达）。
##
## 抽成纯函数来测：面板本体要字体、主题和真实尺寸，测起来很重，
## 而这里要守的只是窗口计算。

var passed := 0
var failed := 0


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _init() -> void:
	await process_frame

	print("── 1 条目少时全部显示 ──")
	var few := GameHUD.task_window(3, 0, 5)
	check("1. 3 条全部可见", int(few["count"]) == 3 and int(few["start"]) == 0, str(few))

	print("── 2 能放几行就放几行，不再卡 5 行 ──")
	var many := GameHUD.task_window(12, 0, 8)
	check("2. 有 8 行空间就显示 8 条", int(many["count"]) == 8, str(many))
	var six := GameHUD.task_window(12, 0, 6)
	check("2b. 有 6 行空间就显示 6 条（旧实现只给 5）", int(six["count"]) == 6, str(six))

	print("── 3 滚到底能看到最后一条 ──")
	var last := GameHUD.task_window(12, 999, 8)
	check("3. 末窗口从第 4 条开始", int(last["start"]) == 4, str(last))
	check("3b. 窗口覆盖到最后一条", int(last["start"]) + int(last["count"]) == 12, str(last))

	print("── 4 边界 ──")
	check("4. 负数滚动夹到 0", int(GameHUD.task_window(12, -5, 8)["start"]) == 0)
	check("4b. 空列表不显示任何行", int(GameHUD.task_window(0, 0, 8)["count"]) == 0)
	check("4c. 行数传 0 时按 1 行算，不会除零", int(GameHUD.task_window(3, 0, 0)["count"]) == 1)
	check("4d. 滚动值被夹回合法范围", int(GameHUD.task_window(12, 999, 8)["scroll"]) == 4)

	print("── 5 滚轮只在列表上生效 ──")
	# 面板外滚轮要留给别处（相机缩放等），不能被待办列表吃掉。
	var hud := GameHUD.new()
	root.add_child(hud)
	hud._task_rect = Rect2(900, 144, 340, 276)
	hud._task_total = 12
	hud._task_rows = 5
	check("5. 指针在列表上时吃掉滚轮", hud.scroll_tasks(false, Vector2(1000, 200)) == true)
	check("5b. 指针在面板外不吃", hud.scroll_tasks(false, Vector2(400, 200)) == false)
	hud._task_scroll = 0
	for i in 20:
		hud.scroll_tasks(false, Vector2(1000, 200))
	check("5c. 滚到底就停住（不会越滚越远）", hud._task_scroll == 7, str(hud._task_scroll))
	hud.queue_free()

	quit(0 if failed == 0 else 1)
