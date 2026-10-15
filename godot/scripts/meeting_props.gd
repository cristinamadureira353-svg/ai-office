class_name MeetingProps
extends Node2D
## 五个座位和长桌参与同一 Y-sort；后端就座状态只更新标记。
const CELL := 32.0
var seats: Dictionary = {"m3":Vector2i(31,7),"flash":Vector2i(33,7),"kimi":Vector2i(35,7),"longcat":Vector2i(32,11),"step5":Vector2i(34,11)}
var table_pos := Vector2i(33,9)
var occupied: Dictionary = {}
var chair_nodes: Dictionary = {}
var table_node: Sprite2D

func _ready() -> void:
	y_sort_enabled = true
	table_node = OfficeArt.sprite("meeting_table", Vector2(table_pos) * CELL + Vector2(0, 1.3 * CELL), 255)
	add_child(table_node)
	for who in seats:
		var seat: Vector2i = seats[who]
		var id := "meeting_chair_front" if seat.y < table_pos.y else "meeting_chair_back"
		# 北侧的正面椅背在人物后方；南侧椅背遮住人物腰腿。
		var holder := Node2D.new()
		holder.name = "Seat_" + who
		var depth := -.2 if seat.y < table_pos.y else .6
		holder.position = Vector2(seat) * CELL + Vector2(0, depth * CELL)
		var chair := OfficeArt.sprite(id, Vector2(0, (.6 - depth) * CELL), 48)
		holder.add_child(chair)
		add_child(holder)
		chair_nodes[who] = holder

func update_from(d: Dictionary) -> void:
	var remote = d.get("seats")
	if remote is Dictionary:
		for who in chair_nodes:
			if remote.has(who):
				var p: Array = remote[who]
				seats[who] = Vector2i(int(p[0]), int(p[1]))
				var depth := -.2 if seats[who].y < table_pos.y else .6
				chair_nodes[who].position = Vector2(seats[who]) * CELL + Vector2(0, depth * CELL)
	var t = d.get("table")
	if t is Array and t.size() == 2:
		table_pos = Vector2i(int(t[0]),int(t[1]))
		table_node.position = Vector2(table_pos) * CELL + Vector2(0, 1.3 * CELL)
	occupied.clear()
	for w in d.get("workers", []):
		if w.get("seated", false):
			occupied[String(w["id"])] = true
	queue_redraw()

func _draw() -> void:
	for who in occupied:
		if seats.has(who):
			draw_arc(Vector2(seats[who]) * CELL + Vector2(0, 6), 15, 0, TAU, 24, UITheme.worker_color(who), 2)
