class_name OfficeView
extends Node2D
## 办公区场景容器。
## 遮挡靠 Y-sort：本节点 y_sort_enabled=true，地板 z_index 压低，角色按 y 自动排序。

const CELL := 32.0

var md: MapData
var tile_layer: TileMapBuilderV2
var deco_layer: Node2D
var _label_slot_seq := 0
var _client_slot_seq := 0
var unit_layer: Node2D
var cam_dir: CameraDirector
var client_layer: Node2D
var props: MeetingProps


func _ready() -> void:
	y_sort_enabled = true          # 遮挡核心：子节点按 y 排序
	md = MapData.load_from()
	tile_layer = TileMapBuilderV2.new()   # M3-5 起用真实 sprite 铺地板
	tile_layer.setup(md)
	tile_layer.z_index = -100       # 地板永远在最下
	add_child(tile_layer)

	# 静态道具：和角色在同一个 y_sort 上下文里，桌子才能正确挡住角色下半身
	deco_layer = Node2D.new()
	deco_layer.name = "Deco"
	deco_layer.y_sort_enabled = true
	add_child(deco_layer)
	_populate_deco()

	unit_layer = Node2D.new()
	unit_layer.name = "Units"
	unit_layer.y_sort_enabled = true
	add_child(unit_layer)

	client_layer = Node2D.new()
	client_layer.name = "Clients"
	client_layer.y_sort_enabled = true
	add_child(client_layer)

	# 会议室家具画在地板之上、角色之下
	props = MeetingProps.new()
	props.name = "Props"
	props.y_sort_enabled = true
	add_child(props)

	# 摄像机由 CameraDirector 负责（一张大图 + 三区聚焦）
	cam_dir = CameraDirector.new()
	cam_dir.name = "CameraDirector"
	add_child(cam_dir)
	cam_dir.setup(md)

	print("[OFFICE] 场景构建 %d×%d，墙 %d，地点 %d，ysort=%s，地图 %dx%d" %
			[md.grid_w, md.grid_h, md.walls.size(), md.locations.size(),
			 y_sort_enabled, int(md.grid_w * 32), int(md.grid_h * 32)])


func update_props(d: Dictionary) -> void:
	if props:
		props.update_from(d)


## 按 scene_layout.json 把静态道具摆出来
func _populate_deco() -> void:
	if tile_layer == null or deco_layer == null:
		return
	var placed := 0
	for p in tile_layer.layout.get("props", []):
		if p.get("role", "") in ["table", "seat"]:
			continue
		var s: Sprite2D = tile_layer.prop_node(p)
		if s:
			s.name = "P_" + str(p.get("prop", ""))
			if p.get("layer", "") == "floor":
				s.z_index = -90
			if p.get("role", "") in ["rest_seat", "work_desk"]:
				var holder := Node2D.new()
				var depth := float(p["seat_y"]) - .2 if p["role"] == "rest_seat" else float(p["sort_y"])
				holder.position = Vector2(s.position.x, depth * CELL)
				s.position -= holder.position
				holder.add_child(s)
				deco_layer.add_child(holder)
			else:
				deco_layer.add_child(s)
			placed += 1
	if placed == 0:
		push_warning("[OFFICE] 一个道具都没摆上，检查 data/scene_layout.json 与 assets/cozy_office/")
	print("[OFFICE] 静态道具 %d 个" % placed)


## 这个格子是不是被墙或家具占着。
func _cell_blocked(cell: Vector2i) -> bool:
	if md.is_wall(cell):
		return true
	for p in tile_layer.layout.get("props", []):
		for c in p.get("blocked_cells", []):
			if Vector2i(int(c[0]), int(c[1])) == cell:
				return true
	return false


## Chief 的主管位：会议室主桌一头的干净格子。找不到干净位置就返回 (-1,-1)，
## 由调用方退回员工面板里的只读条目。
func chief_spot() -> Vector2i:
	if md == null or tile_layer == null:
		return Vector2i(-1, -1)
	var table: Dictionary = {}
	for p in tile_layer.layout.get("props", []):
		if String(p.get("prop", "")) == "meeting_table":
			table = p
			break
	var cells: Array = table.get("blocked_cells", [])
	if cells.is_empty():
		return Vector2i(-1, -1)
	var max_x := -999
	var min_y := 999
	var max_y := -999
	for c in cells:
		max_x = maxi(max_x, int(c[0]))
		min_y = mini(min_y, int(c[1]))
		max_y = maxi(max_y, int(c[1]))
	# 主桌长边朝东西，主管位就在桌子一头；找不到就往外一圈圈找。
	var head := Vector2i(max_x + 1, (min_y + max_y) / 2)
	for radius in range(0, 5):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) != radius:
					continue
				var cell := head + Vector2i(dx, dy)
				if not md.in_bounds(cell) or _cell_blocked(cell):
					continue
				return cell
	return Vector2i(-1, -1)


## 在 unit_layer 上挂一个角色（M1-4 起使用）
func spawn_worker(who: String, script_res: String) -> Node2D:
	if unit_layer == null:
		push_error("unit_layer 尚未创建")
		return null
	if not ResourceLoader.exists(script_res):
		push_error("角色脚本不存在：%s" % script_res)
		return null
	var w := Node2D.new()
	w.set_script(load(script_res))
	# M4-6：按生成顺序分配标签错位槽。同区域的人标签分行，避免糊成一坨
	if "label_slot" in w:
		w.label_slot = _label_slot_seq
		_label_slot_seq += 1
	w.name = "W_" + who
	unit_layer.add_child(w)
	if w.has_method("setup_worker"):
		w.call("setup_worker", who, md)
	return w
