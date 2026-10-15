class_name ClientNode
extends Node2D
## 一个等待中的客户。出生在大门，走到接待处排队。

const CELL := 32.0
const SPRITE_DIR := "res://assets/cozy_office/resources/clients/"
## M3-7 的五种人形（DESIGN 5.1）
const PERSONAS := ["normal", "boss", "client_hard", "geek", "young"]
const PERSONA_NAME := {
	"normal": "普通上班族", "boss": "创业公司老板",
	"client_hard": "甲方大人", "geek": "极客程序员", "young": "年轻客户",
}

var cid: String = ""
var task: String = ""
var reward: int = 0
var patience := 100.0
var patience_max := 100.0
var status := "等待"
var served_by := ""
var body_color := Color("#ffd166")
var persona := "normal"         # M3-7：人形，决定用哪张 sprite
var arrived := false            # 是否已走到队列位
var _tex: Dictionary = {}

var _queue_pos: Vector2 = Vector2.ZERO
var _pos: Vector2 = Vector2.ZERO
var _walk_speed := 2.6 * CELL
var body: Sprite2D
var md: MapData
var _path: Array[Vector2i] = []
var leaving := false
var _label_font_size := 0


func setup(d: Dictionary) -> void:
	cid = String(d.get("id", ""))
	task = String(d.get("task", ""))
	reward = int(d.get("reward", 0))
	patience = float(d.get("patience", 100))
	patience_max = maxf(1.0, float(d.get("patience_max", 100)))
	status = String(d.get("status", "等待"))
	served_by = "" if d.get("served_by") == null else String(d.get("served_by"))
	body_color = _color_for(cid)
	# ★人形没给就退回 normal，不能拿空串去拼路径（会静默丢图）
	persona = String(d.get("persona", "normal"))
	if not PERSONAS.has(persona):
		persona = "normal"

	var nx := float(d.get("x", 1.0))
	var ny := float(d.get("y", 12.0))
	if position == Vector2.ZERO and _pos == Vector2.ZERO:
		_pos = Vector2(nx, ny) * CELL
		position = _pos
	var qx := float(d.get("queue_x", 7.0))
	var qy := float(d.get("queue_y", 8.0))
	_queue_pos = Vector2(qx, qy) * CELL
	arrived = position.distance_to(_queue_pos) < 2.0
	if md == null:
		md = MapData.load_from()
	if body == null:
		body = Sprite2D.new()
		body.centered = false
		body.material = OfficeArt.clean_material()
		body.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(body)
	body.texture = persona_tex()
	body.offset = Vector2(-body.texture.get_width() * .5, -body.texture.get_height())
	body.scale = Vector2.ONE * 70.0 / body.texture.get_height()
	if not arrived and (_path.is_empty() or _path[-1] != Vector2i(_queue_pos / CELL)):
		_path = Pathfinding.find_path(md, Vector2i(position / CELL), Vector2i(_queue_pos / CELL))
	queue_redraw()

func begin_exit() -> void:
	if leaving:
		return
	leaving = true
	arrived = false
	_queue_pos = Vector2(md.loc_pos("entrance")) * CELL
	_path = Pathfinding.find_path(md, Vector2i(roundi(position.x / CELL), roundi(position.y / CELL)), md.loc_pos("entrance"))
	if _path.is_empty():
		queue_free()


func persona_tex() -> Texture2D:
	if _tex.has(persona):
		return _tex[persona]
	var id: String = {"normal":"client_normal", "boss":"client_founder", "client_hard":"client_hard", "geek":"client_geek", "young":"client_young"}.get(persona, "client_normal")
	var t := OfficeArt.texture(id)
	_tex[persona] = t
	return t


func persona_label() -> String:
	return String(PERSONA_NAME.get(persona, "普通上班族"))


static func _color_for(id: String) -> Color:
	# 同色系按 id 散列取色，保证同一客户每次进来颜色一致
	# 注意用 absi 而不是 abs：abs 的返回值类型是 Variant，:= 无法推断
	var h := absi(id.hash())
	var hue := float(h % 100) / 100.0
	return Color.from_hsv(hue, 0.55, 0.95)


func _process(delta: float) -> void:
	var fs := UITheme.world_font_size(self, 13)
	if fs != _label_font_size:
		_label_font_size = fs
		queue_redraw()
	if arrived or _path.is_empty():
		return
	var budget := _walk_speed * delta
	while budget > 0 and not _path.is_empty():
		var goal := Vector2(_path[0]) * CELL
		var distance := position.distance_to(goal)
		if distance <= budget:
			position = goal
			_path.remove_at(0)
			budget -= distance
		else:
			position = position.move_toward(goal, budget)
			budget = 0
	arrived = _path.is_empty() and position.distance_to(_queue_pos) < 2
	if arrived and leaving:
		queue_free()
	queue_redraw()


## M4-6：排队错位槽，由办公室分配
var label_slot := 0


func visual_rect() -> Rect2:
	return OfficeArt.actor_rect(persona_tex(), 70).grow(5)

func _draw() -> void:
	draw_set_transform(Vector2(0, 2), 0, Vector2(1, .35))
	draw_circle(Vector2.ZERO, 11, Color(0,0,0,.2))
	draw_set_transform(Vector2.ZERO)
	var font := ThemeDB.fallback_font
	var p := clampf(patience / patience_max, 0, 1)
	draw_rect(Rect2(-16, 4, 32, 3), Color("#503924"))
	draw_rect(Rect2(-16, 4, 32 * p, 3), UITheme.BAD if p < .3 else UITheme.GOOD)
	var rt := "%d元" % reward
	UITheme.world_label(self, font, Vector2(0, 32), rt, 13, UITheme.WARN)
