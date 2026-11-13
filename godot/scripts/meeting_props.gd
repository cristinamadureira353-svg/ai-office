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

## ── 站会板（会议室白板） ──────────────────────────────────────────────────
## 纯展示：标题「站会」+ 最多三行团队状态。不发请求、不拦鼠标、不改游戏逻辑。
## 位置照 data/scene_layout.json 的 whiteboard：x=30.8、y=5.8、width=125，
## origin bottom_center；贴图 582×348（manifest.json 的 region）⇒ 屏上 125×74.74，
## 底中心 (985.6, 185.6)。右侧 35.2 起是投影幕布，面板不往右越界就压不到它。
const BOARD_FOOT := Vector2(985.6, 185.6)
const BOARD_W := 125.0
const BOARD_H := 74.74
const BOARD_MAX_LINES := 3
const BOARD_FS := 10
const BOARD_LINE_H := 13.0
const BOARD_PAD := 5.0

var _board: Control = null
var _board_lines: Array = []
var _board_font: Font = null


## 喂站会板内容：最多三行。空数组 = 整个面板不画。
func set_board(lines: Array) -> void:
	var kept: Array = []
	for i in range(min(lines.size(), BOARD_MAX_LINES)):
		var s := String(lines[i])
		if s.is_empty():
			continue
		kept.append(s)
	_board_lines = kept
	if kept.is_empty():
		if _board:
			_board.visible = false
		return
	_ensure_board()
	var r := _board_rect()
	_board.position = r.position
	_board.size = r.size
	_board.visible = true
	_board.queue_redraw()


func _ensure_board() -> void:
	if _board:
		return
	_board_font = ThemeDB.fallback_font
	_board = Control.new()
	_board.name = "StandupBoard"
	# 只看不点：鼠标事件一律放过，办公室的点选、HUD 的按钮都不受影响。
	_board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_board.draw.connect(_draw_board)
	add_child(_board)


## 面板坐在白板面上：底边贴板底内缩 3px，内容高过板面时向上探出。
func _board_rect() -> Rect2:
	var w := BOARD_W - 6.0
	var h := 6.0 + 16.0 + _board_rows().size() * BOARD_LINE_H + 6.0
	return Rect2(BOARD_FOOT.x - BOARD_W * .5 + 3.0, BOARD_FOOT.y - 3.0 - h, w, h)


## 三行按板面可用宽度折行：先按「 / 」拆成一条一行，再对超长单条用 UITheme 的像素折行兜底（最多两段）。
## 不直接硬折整行——板面只有 109px 宽，硬折会把「接口」切成孤零零一个「口」（实测）。
func _board_rows() -> Array:
	var rows: Array = []
	var w := BOARD_W - 6.0 - BOARD_PAD * 2.0
	for line in _board_lines:
		for part in String(line).split(" / "):
			for sub in UITheme.preview_lines(part, int(w), _board_font, BOARD_FS, 2):
				rows.append(sub)
	return rows


func _draw_board() -> void:
	if _board_lines.is_empty() or _board_font == null:
		return
	var size := _board.size
	UITheme.panel(_board, Rect2(Vector2.ZERO, size))
	var inner_w := size.x - BOARD_PAD * 2.0
	UITheme.text_in(_board, _board_font, Rect2(BOARD_PAD, 3.0, inner_w, 16.0), "站会", 11, UITheme.WARN)
	var rows := _board_rows()
	for i in rows.size():
		UITheme.text_in(_board, _board_font,
			Rect2(BOARD_PAD, 20.0 + i * BOARD_LINE_H, inner_w, BOARD_LINE_H),
			String(rows[i]), BOARD_FS, UITheme.TEXT)
