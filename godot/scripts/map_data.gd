class_name MapData
extends RefCounted
## 地图数据加载与通行性判断。
## 数据来源：后端 game.py 经 tools/export_map.py 导出（单一数据源，避免两边不一致）。

var name: String = "office"
var label: String = ""
var grid_w: int = 26
var grid_h: int = 15
var walls: Dictionary = {}          # Vector2i -> true
var architecture_walls: Dictionary = {}
var locations: Dictionary = {}      # String -> Vector2i
var loc_label: Dictionary = {}      # String -> String
var can_go: Dictionary = {}         # who -> Array[String]
var spawn: Dictionary = {}          # who -> Vector2i
var rest_seats: Dictionary = {}     # who -> 寻路点与相对家具的坐垫接触点

const PATH := "res://data/map_office.json"


static func load_from(path: String = PATH) -> MapData:
	var md := MapData.new()
	if not FileAccess.file_exists(path):
		push_error("地图文件不存在：%s" % path)
		return md
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("地图文件打不开：%s" % path)
		return md
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("地图 JSON 格式错误")
		return md

	md.name = parsed.get("name", "office")
	md.label = parsed.get("label", "")
	md.grid_w = int(parsed["grid"]["w"])
	md.grid_h = int(parsed["grid"]["h"])
	for p in parsed.get("walls", []):
		md.walls[Vector2i(int(p[0]), int(p[1]))] = true
	for p in parsed.get("architecture_walls", parsed.get("walls", [])):
		md.architecture_walls[Vector2i(int(p[0]), int(p[1]))] = true
	for k in parsed.get("locations", {}):
		var v = parsed["locations"][k]
		md.locations[k] = Vector2i(int(v[0]), int(v[1]))
	md.loc_label = parsed.get("loc_label", {})
	md.can_go = parsed.get("can_go", {})
	for k in parsed.get("spawn", {}):
		var v = parsed["spawn"][k]
		md.spawn[k] = Vector2i(int(v[0]), int(v[1]))
	var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scene_layout.json"))
	for prop in layout.get("props", []):
		for seat in prop.get("seats", []):
			var approach: Array = seat["approach"]
			var contact: Array = seat["contact_offset"]
			md.rest_seats[str(seat["worker"])] = {
				"approach": Vector2i(int(approach[0]), int(approach[1])),
				"contact": Vector2(float(prop["x"]) + float(contact[0]), float(prop["y"]) + float(contact[1]))}
	return md


func in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < grid_w and p.y < grid_h


func is_wall(p: Vector2i) -> bool:
	return walls.has(p)


func is_passable(p: Vector2i) -> bool:
	return in_bounds(p) and not is_wall(p)


func loc_pos(key: String) -> Vector2i:
	return locations.get(key, Vector2i(-1, -1))


func loc_display(key: String) -> String:
	return loc_label.get(key, key)
