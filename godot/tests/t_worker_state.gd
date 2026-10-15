extends SceneTree
## M1-4 角色状态机单测（T1）。重点验"未知 acting 必须回落 IDLE，不能崩"。

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
	# 用例 1-6：acting → 状态
	var cases := [
		["在摸鱼",              Worker.State.SLACK],
		["去茶水间",            Worker.State.WALK],
		["干活中",              Worker.State.WORK],
		["在茶水间休息",        Worker.State.REST],
		["外星语乱码",          Worker.State.IDLE],     # 必须回落
		["",                    Worker.State.IDLE],
	]
	for c in cases:
		var got: int = Worker.map_state(c[0])
		check("映射 \"%s\" → %d" % [c[0], int(c[1])], got == int(c[1]), "得到 %d" % got)

	# null 也必须安全
	var got_null: int = Worker.map_state(null)
	check("映射 null → IDLE 不崩", got_null == Worker.State.IDLE, "得到 %d" % got_null)

	# 补充：更多真实后端取值
	var extra := [
		["在工位",   Worker.State.IDLE],
		["在工位待命", Worker.State.IDLE],
		["去接客户", Worker.State.WALK],
		["去抢单",   Worker.State.WALK],
		["回去交付", Worker.State.WALK],
		["开会中",   Worker.State.ARGUE],
		["闲逛",     Worker.State.IDLE],
	]
	var bad := 0
	for e in extra:
		if Worker.map_state(e[0]) != int(e[1]):
			bad += 1
			print("      误映射: \"%s\" → %d（期望 %d）" % [e[0], Worker.map_state(e[0]), int(e[1])])
	check("7 条真实取值映射正确", bad == 0, "%d 条错" % bad)

	# 体力低 → 移速下降
	var w := Worker.new()
	w.setup_worker("m3", MapData.load_from())
	w.set_data({"name": "M3", "color": "#7DC6FF", "acting": "去茶水间",
			"stamina": 20, "stamina_max": 100, "mood": 60, "log": []})
	check("体力低 → 移速下降", w.speed_mul < 1.0, "speed_mul=%s" % w.speed_mul)
	w.set_data({"name": "M3", "color": "#7DC6FF", "acting": "去茶水间",
			"stamina": 90, "stamina_max": 100, "mood": 60, "log": []})
	check("体力足 → 移速正常", w.speed_mul == 1.0, "speed_mul=%s" % w.speed_mul)

	# 颜色解析
	check("合法颜色解析", Worker._parse_color("#FF6B6B") == Color("#FF6B6B"))
	check("非法颜色回落不崩", Worker._parse_color("不是颜色") == Color("#7DC6FF"))
	w.free()

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("WORKER STATE PASS" if failed == 0 else "WORKER STATE FAIL")
	quit(0 if failed == 0 else 1)
