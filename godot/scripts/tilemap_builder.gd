class_name TileMapBuilder
extends Node2D
## 从 MapData 画出办公室地板、墙、地点标签。
## M3 美术接入后由 tilemap_builder_v2 替换，这里先用 _draw() 保证 M1 就能跑。

const CELL := 32.0

var md: MapData
var cell: float = CELL

var col_floor_a := Color("#131823")
var col_floor_b := Color("#161c28")
var col_wall := Color("#2a3444")
var col_wall_top := Color("#3a4658")
var col_loc := Color("#1d2536")
var col_loc_edge := Color(0.24, 0.42, 0.83, 0.55)
var col_loc_text := Color("#8fa3c4")


func setup(data: MapData) -> void:
	md = data
	queue_redraw()


func _ready() -> void:
	if md == null:
		md = MapData.load_from()
	queue_redraw()


func _draw() -> void:
	if md == null:
		return
	var w := md.grid_w * cell
	var h := md.grid_h * cell

	# 地板（棋盘格）
	for y in md.grid_h:
		for x in md.grid_w:
			var p := Vector2(x * cell, y * cell)
			draw_rect(Rect2(p, Vector2(cell, cell)),
					col_floor_b if (x + y) % 2 == 1 else col_floor_a)

	# 墙（带顶部高光，制造一点立体感）
	for key in md.walls:
		var k: Vector2i = key
		var p := Vector2(k.x * cell, k.y * cell)
		draw_rect(Rect2(p, Vector2(cell, cell)), col_wall)
		draw_rect(Rect2(p, Vector2(cell, 3)), col_wall_top)

	# 地点区块
	var font := ThemeDB.fallback_font
	for key in md.locations:
		var k2: Vector2i = md.locations[key]
		var c := Vector2(k2.x * cell, k2.y * cell)
		var r := Rect2(c - Vector2(cell * 1.5, cell * 1.1), Vector2(cell * 3, cell * 2.2))
		draw_rect(r, col_loc)
		draw_rect(r, col_loc_edge, false, 2.0)
		var label := md.loc_display(key)
		var fs := int(cell * 0.42)
		var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, c - Vector2(tw / 2.0, -font.get_ascent(fs) * 0.32), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col_loc_text)

	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), Color(0.13, 0.16, 0.21, 0.9), false, 2.0)
