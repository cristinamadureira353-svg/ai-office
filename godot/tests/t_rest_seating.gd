extends SceneTree
## 休息区坐垫接触点与寻路落脚点分离；不连接真实后端。
var passed := 0
var failed := 0

func check(label: String, good: bool) -> void:
	passed += int(good)
	failed += int(not good)
	print("PASS " if good else "FAIL ", label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var md := MapData.load_from()
	var approaches := {"flash":Vector2i(17,21), "longcat":Vector2i(20,21), "step5":Vector2i(23,21)}
	var contacts := {"flash":Vector2(18,20.8), "longcat":Vector2(19.7,20.8), "step5":Vector2(22.6,21.2)}
	for who in approaches:
		var w := Worker.new()
		root.add_child(w)
		w.setup_worker(who, md)
		w.set_process(false)
		w.set_physics_process(false)
		w.position = Vector2(approaches[who]) * 32
		w.set_data({"id":who,"name":who,"acting":"在摸鱼"})
		w._process(.1)
		var hip := w.position + w.body.position + (w.body.offset + Vector2(160,360)) * w.body.scale
		check(who + " 臀部落在真实坐垫中心", hip.distance_to(contacts[who] * 32) < .2)
		check(who + " 寻路落脚点仍可通行", w.position == Vector2(approaches[who]) * 32 and md.is_passable(w.grid_pos()))
		check(who + " 确认坐下后才播放坐姿", w.pose == "sit_down")
		var drawn_center := w.body.position + Vector2(0,-35)
		check(who + " 鼠标选取范围包含偏移后的身体", w.visual_rect().has_point(drawn_center))
		var frozen := w.body.position
		w.set_data({"id":who,"name":who,"acting":"脑袋宕机了","brain_down":true})
		w._process(.5)
		check(who + " 宕机保持原座位且停止移动", w.body.position == frozen and not w.moving)
		w.set_data({"id":who,"name":who,"acting":"在摸鱼"})
		w.set_path(Pathfinding.find_path(md, w.grid_pos(), md.spawn[who]), md.spawn[who])
		w._process(.1)
		check(who + " 离座行走清除坐垫偏移", w.pose == "walk" and w.body.position == Vector2.ZERO)
		var passable := true
		for step in range(400):
			w._physics_process(.1)
			passable = passable and md.is_passable(w.grid_pos())
			if not w.moving:
				break
		check(who + " 离座返回工位全程不穿家具", not w.moving and passable and w.grid_pos() == md.spawn[who])
		w._process(.1)
		check(who + " 返回工位恢复椅子坐姿", w.pose == "sit_up" and w.body.position == Vector2.ZERO)
		w.stop()
		w.position = Vector2(21,18) * 32
		w._process(.1)
		check(who + " 地板上不凭状态文本凭空坐下", w.pose == "idle" and w.body.position == Vector2.ZERO)
		w.free()
	print("REST SEATING: %d passed, %d failed" % [passed,failed])
	quit(0 if failed == 0 else 1)
