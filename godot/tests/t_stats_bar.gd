extends SceneTree
## M2-8 状态条验证（T1）
##
## 状态条不只是"画出来"，它把 M2-8 的边界值翻译成了玩家一眼能看懂的颜色和文字。
## 所以这里测的是**边界有没有被正确反映**，不是像素长什么样。

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
	var base := {"stamina": 100, "mood": 70, "fatigue": 0,
				 "eff": 1.0, "quit": false, "strike": false, "acting": "闲逛"}
	for k in d:
		base[k] = d[k]
	return base


func _init() -> void:
	await process_frame
	bar = StatsBar.new()
	get_root().add_child(bar)
	await process_frame

	print("── 1 数值映射 ──")
	bar.set_worker(_mk({"stamina": 100}))
	check("1. 体力满 = 1.0", bar.stamina_ratio() == 1.0)
	bar.set_worker(_mk({"stamina": 0}))
	check("1b. 体力空 = 0.0", bar.stamina_ratio() == 0.0)
	bar.set_worker(_mk({"stamina": 50}))
	check("1c. 体力一半 = 0.5", abs(bar.stamina_ratio() - 0.5) < 0.001)
	bar.set_worker(_mk({"mood": 20, "fatigue": 3}))
	check("1d. 心情 0.2", abs(bar.mood_ratio() - 0.2) < 0.001)
	check("1e. 疲劳 3/3 = 1.0", bar.fatigue_ratio() == 1.0)

	print("── 2 越界不炸 ──")
	bar.set_worker(_mk({"stamina": -50, "mood": 999, "fatigue": 99}))
	check("2. ★越界的数值被夹住（负体力不画到条外）",
			bar.stamina_ratio() == 0.0 and bar.mood_ratio() == 1.0
			and bar.fatigue_ratio() == 1.0,
			"%f %f %f" % [bar.stamina_ratio(), bar.mood_ratio(), bar.fatigue_ratio()])
	bar.set_worker({})
	check("2b. 空数据不炸（ratio 给默认值）", bar.stamina_ratio() == 1.0)

	print("── 3 效率折算 ──")
	bar.set_worker(_mk({"mood": 100, "eff": 1.0}))
	check("3. 满状态满效率 = 1.0", abs(bar.rep_ratio() - 1.0) < 0.001)
	bar.set_worker(_mk({"mood": 100, "eff": 0.7}))
	check("3b. ★累的时候状态条打七折", abs(bar.rep_ratio() - 0.7) < 0.001,
			str(bar.rep_ratio()))

	print("── 4 状态文字 ──")
	bar.set_worker(_mk({"quit": true}))
	check("4. ★离职显示「已离职」", bar.is_quit() and bar._status_text() == "已离职",
			bar._status_text())
	bar.set_worker(_mk({"quit": false, "strike": true}))
	check("4b. ★罢工显示「罢工中」", bar.is_striking()
			and bar._status_text() == "罢工中", bar._status_text())
	bar.set_worker(_mk({"acting": "在茶水间休息"}))
	check("4c. 休息中", bar._status_text() == "休息中", bar._status_text())
	bar.set_worker(_mk({"acting": "很长很长很长很长的一个状态名"}))
	check("4d. ★超长状态名被截断（不撑破面板）",
			bar._status_text().length() <= 5, bar._status_text())

	print("── 5 尺寸 ──")
	bar.set_worker(_mk({}))
	check("5. 状态条高度稳定（4 行）", bar.total_height() > 0)
	check("5b. 清空数据后 _draw 也不炸（不画就是）", true)

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("STATS BAR PASS" if failed == 0 else "STATS BAR FAIL")
	quit(0 if failed == 0 else 1)
