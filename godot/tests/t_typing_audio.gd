extends SceneTree
## M4-2 打字音效单节测试
##
## 跑法：./run_test.sh res://tests/t_typing_audio.gd
##
## ★计划要求"衰减必须是量化数字，不是听着对"，所以这里全部用可断言的数：
##   线性增益比、触发次数/秒、间隔毫秒数。没有一条是靠"听起来"过的。

var pass_n := 0
var fail_n := 0
var _TA: Node2D = null


func _init() -> void:
	print("── M4-2 打字音效 ──")
	await _run()
	_teardown()
	print("═".repeat(52))
	if fail_n == 0:
		print("✓ 通过 %d / %d" % [pass_n, pass_n + fail_n])
	else:
		print("✗ 失败 %d 条（通过 %d）" % [fail_n, pass_n])
	quit(0 if fail_n == 0 else 1)


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		pass_n += 1
		print("  PASS  %s" % name)
	else:
		fail_n += 1
		print("  FAIL  %s  %s" % [name, detail])


func _run() -> void:
	var T: GDScript = load("res://scripts/typing_audio.gd")
	_TA = T.new()
	root.add_child(_TA)
	await process_frame

	var p: Dictionary = _TA.probe()
	var max_d: float = p["max_d"]

	# ══ 1 资源就位 ══
	check("1a. 五个角色各一个播放器", p["players"] == 5, str(p["players"]))
	check("1b. ★五个打字素材都加载成功", p["streams"] == 5, str(p["streams"]))
	check("1c. 基础间隔五种手速各不相同",
		_thinking_five_different(), str(p["base_ms"]))

	# ══ 2 距离衰减（★核心量化判据）══
	# 计划的原话是「屏幕中心音量 ≥ 屏幕边缘 2 倍」。屏幕 1280 宽，
	# 中心到左右边缘 640px，而 max_distance=400 —— 边缘本来就已在衰减范围外。
	# 那样这条判据会**恒真、白测**，所以拆成两个都有内容的要求：
	#   2a 中心 vs 半程（200px，在范围内）比值 ≥ 2 —— 这才是"明显更响"
	#   2b 中心 vs 屏幕边缘（640px）必须完全听不见
	# T 是 GDScript 资源，经它调 static 方法返回 Variant，赋给 float 变量要显式转
	var g0: float = float(T.atten_gain(0.0))
	var g200: float = float(T.atten_gain(200.0))
	var g400: float = float(T.atten_gain(max_d))
	var g640: float = float(T.atten_gain(640.0))
	check("2a. ★中心比半程(200px)响 ≥2 倍",
		g0 >= 2.0 * maxf(g200, 0.0001), "%.3f vs %.3f = %.2f×" % [g0, g200, g0 / g200])
	check("2b. ★屏幕边缘(640px)完全听不见", g640 <= 0.0, "%.4f" % g640)
	check("2c. 恰好在 max_distance 处归零", g400 <= 0.0, "%.4f" % g400)
	check("2d. 刚好越过 max_distance 一点也是零", float(T.atten_gain(max_d + 0.1)) <= 0.0)
	# 曲线本身：单调、连续、夹在 [0,1]
	var mono := true
	var prev := 1.1
	for i in range(0, 41):
		var d := float(i) * 10.0
		var g: float = float(T.atten_gain(d))
		if g > prev + 1e-9 or g < -1e-9 or g > 1.0 + 1e-9:
			mono = false
		prev = g
	check("2e. ★衰减曲线单调不增且恒在 [0,1]", mono)
	check("2f. dB 值在 %d~-60 之间" % 0,
		float(T.atten_db(0.0)) >= -0.001 and float(T.atten_db(max_d)) <= -59.9,
		"%.2f / %.2f" % [float(T.atten_db(0.0)), float(T.atten_db(max_d))])
	# 负距离（插值可能短暂越界）不能炸
	check("2g. 负距离被夹住",
		float(T.atten_gain(-30.0)) == 1.0 and float(T.atten_db(-30.0)) >= -0.001)

	var min_ms: float = p["min_ms"]
	var max_ms: float = p["max_ms"]

	# ══ 3 节奏跟输出速率同步 ══
	# 计划用 M3 / Flash 两个代表就够：同一角色、同一手速，
	# 只有 cps 变，间隔必须明显变短。
	var slow := float(_TA.interval_of("m3", 0.0))
	var fast := float(_TA.interval_of("m3", 240.0))
	check("3a. ★cps 高时间隔更短（跟模型输出同步）", fast < slow * 0.6,
		"0字/s→%.0fms  240字/s→%.0fms" % [slow, fast])
	# 五个人即使同一个 cps，手速也必须分得开。
	# ★在**低速区**验（cps=0）——手速是"没人催的时候"才听得出来的东西。
	#   高速区五人一起撞到 MIN_MS 下限那是**正确**的防音爆行为，另有一条专门验。
	var i_m3 := float(_TA.interval_of("m3", 0.0))
	var i_fl := float(_TA.interval_of("flash", 0.0))
	var i_lo := float(_TA.interval_of("longcat", 0.0))
	var i_ki := float(_TA.interval_of("kimi", 0.0))
	var i_st := float(_TA.interval_of("step5", 0.0))
	check("3b. ★低速区 Kimi 最慢、Flash 最快", i_ki > i_m3 and i_fl < i_m3,
		"kimi %.0f / m3 %.0f / flash %.0f" % [i_ki, i_m3, i_fl])
	# ★快慢序（慢 → 快）：kimi 168 > m3 145 > longcat 112 > step5 86 > flash 78。
	#   我第一版把 m3/longcat 的比较方向写反了（以为 LongCat 比 M3 慢），
	#   实现是对的、判据是错的——DESIGN 4.1 写的是 M3 慢而稳、LongCat 中等平稳。
	check("3c. 快慢序 step5 < longcat < m3（重而急 / 中等 / 慢而稳）",
		i_st < i_lo and i_lo < i_m3, "step5 %.0f / longcat %.0f / m3 %.0f"
		% [i_st, i_lo, i_m3])
	check("3e. ★低速区五人两两不同（顺序 kimi>m3>longcat>step5>flash）",
		i_ki > i_m3 and i_m3 > i_lo and i_lo > i_st and i_st > i_fl)
	# 高速区：**没人能突破下限**。注意 Kimi 抽到"犹豫"时会在夹紧之前被放大
	# （168/2.4 × 2.6 ≈ 182ms），所以他不会正好停在下限上——那是设计（"让我先想想"）。
	# 要验的是下限**托得住**：抽 40 次取最小值。
	var floor_ok := true
	var worst := 1e9
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		for i in range(40):
			var ms := float(_TA.interval_of(who, 5000.0))
			worst = minf(worst, ms)
			if ms < min_ms - 0.001:
				floor_ok = false
	check("3f. ★极高速下没人突破 %.0fms 下限（抽 200 次最小 %.1f）" % [min_ms, worst],
		floor_ok)
	check("3g. ★低速区最快的人也不低于下限（Flash %.0fms ≥ %.0f）" % [i_fl, min_ms],
		i_fl >= min_ms)
	# ★GDScript **不支持链式比较**：`a > b > c` 会被解析成 `(a > b) > c`，
	#   左边变成 bool 再和 float 比，解析期直接报
	#   "Invalid operands bool and float for >"。Python 习惯要改掉。
	var i0 := float(_TA.interval_of("m3", 0.0))
	var i40 := float(_TA.interval_of("m3", 40.0))
	var i120 := float(_TA.interval_of("m3", 120.0))
	var i300 := float(_TA.interval_of("m3", 300.0))
	check("3d. cps 越高间隔单调越短（不抖）", i0 > i40 and i40 > i120 and i120 > i300,
		"%.0f/%.0f/%.0f/%.0f" % [i0, i40, i120, i300])

	# ══ 4 最小间隔：无音爆 ══
	var under := true
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		for cps in [0.0, 60.0, 200.0, 1000.0, 99999.0]:
			var ms := float(_TA.interval_of(who, cps))
			if ms < min_ms - 0.001 or ms > max_ms + 0.001:
				under = false
	check("4a. ★任何组合下间隔都夹在 [%.0f,%.0f]ms" % [min_ms, max_ms], under)
	# 理论上限：1/0.060 = 16.7 次/秒 < 计划要求的 25
	check("4b. ★理论上限 %.1f 次/秒 < 25" % (1000.0 / min_ms),
		1000.0 / min_ms < 25.0)
	# 实测：让 Flash 全速打 10 秒，量真的触发了多少次
	var fired := _run_typing("flash", 2000.0, 10.0)
	var rate: float = fired / 10.0
	check("4c. ★实测全速打字 %.1f 次/秒 < 25" % rate, rate < 25.0, "触发 %d 次" % fired)
	# 五个角色一起跑：合计上限 = 5 × 单源上限，这才有意义。
	# 我第一版直接写了个"总数 <125"，那是拍的——5 个人各 16.7 次/秒本就有 250 次。
	var secs := 3.0
	var total := 0
	for who in ["m3", "flash", "longcat", "kimi", "step5"]:
		total += _run_typing(who, 200.0, secs)
	var cap: float = 5.0 * (1000.0 / min_ms) * secs
	check("4d. ★五人同时打字 %.0fs 共 %d 次，不超合计上限 %.0f" % [secs, total, cap],
		float(total) < cap, "单源上限 %.1f/s × 5" % (1000.0 / min_ms))

	# ══ 5 停止时机 ══
	_TA.sync(_mk_state(true, 200.0, 120.0))
	_TA.tick(20, 0.016)
	var before: int = _TA.probe()["fired"]
	_TA.sync(_mk_state(false, 0.0, 0.0))     # 活干完了
	_TA.tick(120, 0.016)
	var after: int = _TA.probe()["fired"]
	check("5a. ★干完活立刻不再触发（%d → %d）" % [before, after], after == before)
	# 刚开始打字要立刻响第一下（不能等一个完整间隔）
	_TA.sync(_mk_state(true, 200.0, 120.0))
	var f0: int = _TA.probe()["fired"]
	_TA.tick(1, 0.016)
	check("5b. ★刚开始打字第一帧就响（不等满一个间隔）",
		int(_TA.probe()["fired"]) > f0)
	# 静音开关
	_TA.set_muted(true)
	var m0: int = _TA.probe()["fired"]
	_TA.tick(60, 0.016)
	check("5c. 静音后不再触发", int(_TA.probe()["fired"]) == m0)
	_TA.set_muted(false)
	_TA.set("enabled", true)     # enabled 是脚本里的属性，_TA 声明成 Node2D 只能走 set()
	_TA.tick(60, 0.016)
	check("5d. 取消静音后恢复触发", int(_TA.probe()["fired"]) > m0)

	# ══ 6 位置同步 ══
	# 没位置的worker 不该响（_process 里 position==0 直接跳过）
	_TA.sync({"workers": [{"id": "m3", "x": 0.0, "y": 0.0,
		"typing": true, "type_cps": 100.0}]})
	var z0: int = _TA.probe()["fired"]
	_TA.tick(30, 0.016)
	check("6a. 位置未同步的 worker 不发声（不凭空在原点响）",
		int(_TA.probe()["fired"]) == z0)
	# 远处的人不该被听见
	_TA.sync({"workers": [{"id": "m3", "x": 900.0, "y": 0.0,
		"typing": true, "type_cps": 200.0}]})
	var r0: int = _TA.probe()["fired"]
	_TA.tick(60, 0.016)
	check("6b. ★900px 外的人打字听不见", int(_TA.probe()["fired"]) == r0)


func _thinking_five_different() -> bool:
	# ★直接读已建好的那个实例的 base_ms，别 t.new() ——那会每轮多造一个
	#   带 5 个 AudioStreamPlayer2D 的节点，既漏资源又把退出时的报错搞复杂。
	var seen := {}
	var base: Dictionary = _TA.probe()["base_ms"]
	for who in base:
		var ms: float = float(base[who])
		if ms <= 0.0:
			return false
		for v in seen:
			if absf(v - ms) < 0.001:
				return false
		seen[ms] = who
	return seen.size() == 5


## 让某人以给定 cps 打字若干秒，返回真实触发次数
func _run_typing(who: String, cps: float, secs: float) -> int:
	_TA.sync({"workers": [{"id": who, "x": 200.0, "y": 0.0,
		"typing": true, "type_cps": cps}]})
	var f0: int = _TA.probe()["fired"]
	_TA.tick(int(secs / 0.016), 0.016)
	return int(_TA.probe()["fired"]) - f0


func _mk_state(typing: bool, x: float, cps: float) -> Dictionary:
	return {"workers": [{"id": "m3", "x": x, "y": 0.0,
		"typing": typing, "type_cps": cps}]}


func _teardown() -> void:
	if _TA != null and is_instance_valid(_TA):
		for c in _TA.get_children():
			if c is AudioStreamPlayer2D:
				(c as AudioStreamPlayer2D).stream = null
		if _TA.get_parent() != null:
			_TA.get_parent().remove_child(_TA)
		_TA.free()
		_TA = null
