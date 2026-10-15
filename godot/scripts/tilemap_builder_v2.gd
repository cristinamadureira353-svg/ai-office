class_name TileMapBuilderV2
extends Node2D
## V2 连续办公室。脚底坐标、家具尺寸与碰撞格来自同一份布局。

const CELL := 32.0
var md: MapData
var layout: Dictionary = {}
var cell := CELL
var show_labels := true
var _label_font_size := 0

func _ready() -> void:
	if md == null:
		md = MapData.load_from()
	layout = JSON.parse_string(FileAccess.get_file_as_string("res://data/scene_layout.json"))
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()

func setup(data: MapData) -> void:
	md = data

func _process(_delta: float) -> void:
	var fs := UITheme.world_font_size(self, 13)
	if show_labels and fs != _label_font_size:
		_label_font_size = fs
		queue_redraw()

func _tex_for(id: String) -> Texture2D:
	return OfficeArt.texture(id)

func _floor(id: String, rect: Rect2) -> void:
	var texture := _tex_for(id)
	const TILE := 64.0
	for y in range(int(ceil(rect.size.y / TILE))):
		for x in range(int(ceil(rect.size.x / TILE))):
			var point := rect.position + Vector2(x, y) * TILE
			var wh := Vector2(minf(TILE, rect.end.x - point.x), minf(TILE, rect.end.y - point.y))
			draw_texture_rect_region(texture, Rect2(point, wh), Rect2(Vector2.ZERO, texture.get_size() * wh / TILE))

func _wall(id: String, rect: Rect2) -> void:
	var skin := StyleBoxTexture.new()
	skin.texture = _tex_for(id)
	skin.texture_margin_left = 18
	skin.texture_margin_right = 18
	skin.texture_margin_top = 18
	skin.texture_margin_bottom = 18
	skin.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	skin.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	draw_style_box(skin, rect)

func _vertical_walls(x: int, first: int, last: int) -> void:
	var start := -1
	for y in range(first, last + 2):
		var solid := y <= last and md.architecture_walls.has(Vector2i(x, y))
		if solid and start < 0:
			start = y
		if not solid and start >= 0:
			_wall("wall_west", Rect2(x * CELL - 9, (start - .5) * CELL, 18, (y - start) * CELL))
			start = -1

func _horizontal_walls(y: int, first: int, last: int) -> void:
	var start := -1
	for x in range(first, last + 2):
		var solid := x <= last and md.architecture_walls.has(Vector2i(x, y))
		if solid and start < 0:
			start = x
		if not solid and start >= 0:
			_wall("wall_south", Rect2((start - .5) * CELL, y * CELL - 10, (x - start) * CELL, 20))
			start = -1

func _draw() -> void:
	if md == null or layout.is_empty():
		return
	_floor("floor_oak", Rect2(0, 0, md.grid_w * CELL, md.grid_h * CELL))
	_floor("floor_walnut", Rect2(28 * CELL, 0, 11 * CELL, 17 * CELL))
	for patch in layout.get("floor_patches", []):
		var r: Array = patch["rect"]
		_floor(String(patch["prop"]), Rect2(float(r[0]) * CELL, float(r[1]) * CELL, float(r[2]) * CELL, float(r[3]) * CELL))
	_wall("wall_north", Rect2(0, -40, md.grid_w * CELL, 80))
	_wall("wall_south", Rect2(0, 23 * CELL - 12, md.grid_w * CELL, 29))
	_vertical_walls(0, 1, 22)
	_vertical_walls(39, 1, 22)
	_vertical_walls(13, 3, 20)
	_vertical_walls(27, 1, 22)
	_horizontal_walls(2, 22, 26)
	_horizontal_walls(21, 22, 26)
	_horizontal_walls(17, 29, 37)
	for x in [6, 18, 33]:
		var window := _tex_for("window")
		var wh := window.get_size() * 99.0 / window.get_width()
		draw_texture_rect(window, Rect2(Vector2(x * CELL - wh.x * .5, 40 - wh.y), wh), false)
	if show_labels:
		for label in layout.get("labels", []):
			var text := String(label["label"])
			var at := Vector2(float(label["x"]), float(label["y"])) * CELL
			UITheme.world_label(self, ThemeDB.fallback_font, at + Vector2(0, 5), text, 13, UITheme.TEXT)

func prop_node(prop: Dictionary) -> Sprite2D:
	return OfficeArt.sprite(String(prop["prop"]), Vector2(float(prop["x"]), float(prop["y"])) * CELL, float(prop["width"]))
