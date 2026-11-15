extends SceneTree
## 状态条验证（T1）
##
## ★状态条画的是真 Bot 的状态：状态 / 在做什么 / 模型。
##   旧经营玩法的体力 / 心情 / 疲劳 / 声望已经不再变化，不再画它们。
##   所以这里测的是：**真状态有没有被正确翻译成玩家一眼能看懂的颜色和文字**。

var passed := 0
var failed := 0
var bar: StatsBar


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _mk(d: Dictionary) -> Dictionary:
	var base := {"id": "m3", "brain_down": false, "acting": "在工位"}
	for k in d:
		base[k] = d[k]
	return base


func _init() -> void:
	await process_frame
	bar = StatsBar.new()
	get_root().add_child(bar)
	await process_frame

	print("── 1 状态映射 ──")
	bar.set_worker(_mk({}))
	bar.set_bot({"status": "running", "title": "", "model": ""})
	check("1. 执行中显示「忙碌」", bar.status_text() == "忙碌", bar.status_text())
	bar.set_bot({"status": "queued"})
	check("1b. 排队显示「排队中」", bar.status_text() == "排队中", bar.status_text())
	bar.set_bot({"status": "idle"})
	check("1c. 空闲显示「空闲」", bar.status_text() == "空闲", bar.status_text())
	bar.set_bot({"status": "failed"})
	check("1d. 失败显示「失败」", bar.status_text() == "失败", bar.status_text())
	bar.set_bot({"status": "done"})
	check("1e. 完成显示「已完成」", bar.status_text() == "已完成", bar.status_text())
	bar.set_bot({"status": "stale"})
	check("1f. 未绑定显示「未绑定」", bar.status_text() == "未绑定", bar.status_text())
	bar.set_bot({})
	check("1g. 没有真 Bot 状态时退回员工快照", bar.status_text() == "在工位", bar.status_text())
	bar.set_worker(_mk({"working": true}))
	check("1h. worker 报忙也算忙碌", bar.status_text() == "忙碌", bar.status_text())
	bar.set_worker(_mk({"job": "实现登录接口"}))
	check("1i. 手上有一单也算忙碌", bar.status_text() == "忙碌", bar.status_text())
	bar.set_worker(_mk({"acting": "在茶水间休息"}))
	check("1j. 茶水间显示「休息中」", bar.status_text() == "休息中", bar.status_text())
	bar.set_worker(_mk({"acting": ""}))
	check("1k. 什么都没有就是在线", bar.status_text() == "在线", bar.status_text())

	print("── 2 颜色 ──")
	bar.set_worker(_mk({}))
	bar.set_bot({"status": "running"})
	check("2. 忙碌用 WARN 色", bar.status_color() == UITheme.WARN)
	bar.set_bot({"status": "done"})
	check("2b. 完成用 GOOD 色", bar.status_color() == UITheme.GOOD)
	bar.set_bot({"status": "failed"})
	check("2c. 失败用 BAD 色", bar.status_color() == UITheme.BAD)
	bar.set_bot({"status": "idle"})
	check("2d. 空闲用暗色", bar.status_color() == UITheme.TEXT_DIM)
	bar.set_worker(_mk({"brain_down": true}))
	check("2e. ★宕机一律 BAD 色",
		bar.status_color() == UITheme.BAD and bar.status_text() == "脑袋宕机了")

	print("── 3 在做什么 ──")
	bar.set_worker(_mk({}))
	bar.set_bot({"status": "running", "title": "实现登录接口"})
	check("3. 有任务标题就显示标题", bar.task_text() == "实现登录接口", bar.task_text())
	bar.set_bot({"status": "running", "title": ""})
	check("3b. 没有标题就说在干活", bar.task_text() == "在干活", bar.task_text())
	bar.set_bot({"status": "idle", "title": ""})
	check("3c. 空闲就是手上没活", bar.task_text() == "手上没活", bar.task_text())

	print("── 4 越界与空数据 ──")
	var font := ThemeDB.fallback_font
	check("4c. ★标签放得下（不被截成省略号）",
		UITheme.fit("在做什么", 64, font, UITheme.SMALL) == "在做什么",
		UITheme.fit("在做什么", 64, font, UITheme.SMALL))
	bar.set_worker({})
	bar.set_bot({})
	check("4. 空数据不炸", bar.status_text() == "在线" and bar.task_text() == "手上没活")
	check("4b. 状态条高度稳定（2 行）", bar.total_height() == StatsBar.ROW_H * 2.0 + 4.0)

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("STATS BAR PASS" if failed == 0 else "STATS BAR FAIL")
	quit(0 if failed == 0 else 1)
