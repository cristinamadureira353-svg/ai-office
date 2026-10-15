extends SceneTree
## M1-3 寻路单测（T1）。退出码 0 = 通过。

var md: MapData
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
	md = MapData.load_from()
	print("[TEST] 地图：%d×%d，墙 %d，地点 %d" % [md.grid_w, md.grid_h, md.walls.size(), md.locations.size()])

	# 用例 1：正常路径存在
	var p1 := Pathfinding.find_path(md, Vector2i(5, 10), Vector2i(9, 14))
	check("1. (5,10)→(9,14) 路径存在", p1.size() > 0, "得到空路径")

	# 用例 2：路径中每一点都可通行
	var ok2 := p1.size() > 0
	for p in p1:
		if not md.is_passable(p):
			ok2 = false
			print("      穿墙点：", p)
	check("2. 路径无穿墙", ok2)

	# 用例 3：目标在墙内 → 空
	var wall_pt := Vector2i(-1, -1)
	for w in md.walls:
		wall_pt = w
		break
	var p3 := Pathfinding.find_path(md, Vector2i(5, 10), wall_pt)
	check("3. 目标在墙内返回空", p3.is_empty(), "墙点 %s 却算出了 %d 步" % [wall_pt, p3.size()])

	# 用例 4：起点==终点 → 空
	var p4 := Pathfinding.find_path(md, Vector2i(5, 10), Vector2i(5, 10))
	check("4. 起点==终点返回空", p4.is_empty())

	# 用例 5：路径长度合理性
	if p1.size() > 0:
		var mh := Pathfinding.manhattan(Vector2i(5, 10), Vector2i(9, 14))
		var n := p1.size()
		check("5. 长度在 [曼哈顿, 曼哈顿×2+4] 内",
			n >= mh and n <= mh * 2 + 4, "曼哈顿=%d 实际=%d" % [mh, n])
	else:
		check("5. 长度合理性", false, "用例1 无路径，无法测")

	# 用例 6：五个地点两两可达
	var keys := md.locations.keys()
	var unreachable: Array = []
	for a in keys:
		for b in keys:
			if a == b:
				continue
			var pa := Pathfinding.find_path(md, md.loc_pos(a), md.loc_pos(b))
			if pa.is_empty():
				unreachable.append("%s→%s" % [a, b])
	check("6. 五个地点两两可达", unreachable.is_empty(), "不可达：%s" % str(unreachable))

	# 附加：出生点到所有地点可达
	var bad: Array = []
	for who in md.spawn.keys():
		var s: Vector2i = md.spawn[who]
		for k in keys:
			if Pathfinding.find_path(md, s, md.loc_pos(k)).is_empty():
				bad.append("%s→%s" % [who, k])
	check("7. 五个出生点到所有地点可达", bad.is_empty(), str(bad))

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("PATHFINDING PASS" if failed == 0 else "PATHFINDING FAIL")
	quit(0 if failed == 0 else 1)
