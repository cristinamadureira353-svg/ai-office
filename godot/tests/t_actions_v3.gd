extends SceneTree
## 五人动作、行走优先级和客户离场；不装配后端通信。
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
	var seats := {"m3":Vector2i(31,7),"flash":Vector2i(33,7),"kimi":Vector2i(35,7),"longcat":Vector2i(32,11),"step5":Vector2i(34,11)}
	for who in ["m3","flash","longcat","kimi","step5"]:
		var w := Worker.new()
		root.add_child(w)
		w.setup_worker(who, md)
		w.set_process(false)
		w.set_physics_process(false)
		w.set_data({"id":who,"name":who,"acting":"干活中","typing":true})
		w._process(.01)
		var first := w.body.texture
		w._process(1.0 / float(Worker.TYPE_FPS[who]))
		check(who + " 真实键盘双帧且有像素变化", w.pose == "type_up" and w.body.texture != first and w.body.texture.get_image().get_data() != first.get_image().get_data())
		w.data["typing"] = false
		w._process(.1)
		var paused := w.body.texture
		w._process(.6)
		check(who + " 等待输出时停手并坐在工位", w.pose == "sit_up" and w.body.texture == paused)
		w.set_data({"id":who,"name":who,"acting":"开会中","seated":true})
		w.position = Vector2(seats[who]) * 32
		w._process(.1)
		check(who + " 到座位才按桌边朝向坐下", w.pose == ("sit_down" if seats[who].y < 9 else "sit_up"))
		var destination: Vector2i = md.spawn[who]
		w.set_path(Pathfinding.find_path(md, w.grid_pos(), destination), destination)
		w._physics_process(.2)
		w._process(.2)
		check(who + " 离席时播放行走并取消坐姿", w.moving and w.pose == "walk" and w.body.offset.y == -317)
		w.stop()
		w.set_data({"id":who,"name":who,"acting":"在茶水间休息"})
		w.position = Vector2(23,6) * 32
		w._idle_t = 0
		w._process(.01)
		var cup := w.body.texture
		w._process(.9)
		check(who + " 喝咖啡具有举杯帧", w.pose == "drink_down" and w.body.texture != cup)
		w.free()
	var c := ClientNode.new()
	root.add_child(c)
	c.setup({"id":"isolated-client","x":8,"y":8,"queue_x":8,"queue_y":8,"persona":"normal"})
	c.begin_exit()
	var departure_path := c._path.duplicate()
	check("客户离场经过真实门口且不穿家具", not departure_path.is_empty() and departure_path[-1] == md.locations.entrance and departure_path.all(func(p):return md.is_passable(p)))
	c._process(20)
	await process_frame
	check("走到门口后移除客户节点", not is_instance_valid(c))
	print("ACTIONS V3: %d passed, %d failed" % [passed,failed])
	quit(0 if failed == 0 else 1)
