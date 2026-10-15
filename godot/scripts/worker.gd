class_name Worker
extends Node2D
## 员工的落脚点、行走、坐姿、键盘动作和茶水动作。

const CELL := 32.0
const SPRITE_DIR := "res://assets/cozy_office/resources/characters/"
## 行走动画：4 方向 × 2 帧（M3-3 生成，M3-3 的打包器已保证脚底/高度零误差）
const WALK_FPS := 5.0
## V2 素材归一到 256×320；第 317 行是脚底，position 始终是寻路落脚点。
const FOOT_IN_TEX := 317
const ART_SCALE := 0.24
const ACTIVITY_SCALE := 0.20
const SEATED_HIP := Vector2(160, 360)
const TYPE_FPS := {"m3": 4.0, "flash": 7.0, "longcat": 5.0, "kimi": 3.0, "step5": 6.0}
const DIRS := ["down", "up", "left", "right"]

enum State { IDLE, WALK, WORK, REST, SLACK, ARGUE }

var who: String = ""
var data: Dictionary = {}
var md: MapData

# 移动（内联自 Mover；Worker 自己的 position 就是格坐标 * CELL）
var path: Array[Vector2i] = []
var target: Vector2 = Vector2.ZERO
var moving := false
var speed := 2.2
var speed_mul := 1.0

signal step_taken()

var state: int = State.IDLE

# 视觉
var body_color := Color("#7DC6FF")
## M4-6：同区域多人的标签垂直错位槽（0..4），由办公室按生成顺序分配。
## 公开字段——办公室要用 set() 写，私有名外部写不了。
var label_slot := 0
var display_name := "?"
var bar_stamina := 1.0
var bar_mood := 0.7
var acting_text := "闲逛"
var log_lines: Array = []

# M3-8 动画
var body: Sprite2D
var show_detail := false
var _idle_t := 0.0
var _tex: Dictionary = {}          # "dir_frame" -> Texture2D
var _anim_t := 0.0
var _dir := "down"
var _last_pos := Vector2.ZERO
var pose := "idle"
var _frozen_pose := "idle"


func setup_worker(w: String, m: MapData) -> void:
	who = w
	md = m
	var sp: Vector2i = m.spawn.get(w, Vector2i(5, 6))
	position = Vector2(sp) * CELL
	target = position
	_last_pos = position
	if body == null:
		body = Sprite2D.new()
		body.centered = false
		body.offset = Vector2(-128, -FOOT_IN_TEX)
		body.scale = Vector2.ONE * ART_SCALE
		body.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		body.material = OfficeArt.clean_material()
		add_child(body)
	body.texture = walk_frame("down", 1)
	queue_redraw()


## 取某一方向某一帧的行走贴图。取不到返回 null（**不崩，退回色块**）。
func walk_frame(dir: String, frame: int) -> Texture2D:
	var key := dir + "_" + str(frame)
	if _tex.has(key):
		return _tex[key]
	var p := SPRITE_DIR + who + "_walk_" + dir + "_" + str(frame) + ".tres"
	var t: Texture2D = null
	if ResourceLoader.exists(p):
		t = load(p)
	_tex[key] = t
	return t


## 有没有可用的人物素材
func has_sprite() -> bool:
	return walk_frame(_dir, 1) != null


## 按位移方向选朝向。位移太小就保持原朝向（原地抖动会把朝向甩来甩去）。
func _update_dir() -> void:
	var d := position - _last_pos
	_last_pos = position
	if d.length() < 0.35:
		return
	if absf(d.x) > absf(d.y):
		_dir = "right" if d.x > 0.0 else "left"
	else:
		_dir = "down" if d.y > 0.0 else "up"


func set_data(d: Dictionary) -> void:
	if d.get("brain_down", false) and not data.get("brain_down", false):
		_frozen_pose = pose
	data = d
	display_name = d.get("name", who)
	body_color = _parse_color(d.get("color", "#7DC6FF"))
	acting_text = d.get("acting", "闲逛")
	bar_stamina = float(d.get("stamina", 100)) / maxf(1.0, float(d.get("stamina_max", 100)))
	bar_mood = float(d.get("mood", 70)) / 100.0
	log_lines = d.get("log", [])
	if d.get("brain_down", false):
		stop()
		acting_text = "脑袋宕机了"
	if not moving:
		state = map_state(acting_text)
	speed_mul = 1.0 if bar_stamina > 0.3 else 0.6
	queue_redraw()


## ★ acting 文本 → 动画状态。未知值必须回落 IDLE，不能崩。
## 参数用 Variant 而非 String：后端可能给 null，静态类型会直接拒绝。
static func map_state(acting) -> int:
	var s := ""
	if acting != null:
		s = str(acting).strip_edges()
	if s.is_empty():
		return State.IDLE
	if s.contains("干活"):
		return State.WORK
	if s.contains("休息"):
		return State.REST
	if s.contains("摸鱼"):
		return State.SLACK
	if s.contains("抢单") or s.contains("接客户") or s.contains("接单"):
		return State.WALK
	# 移动中：以"去/回"开头，或含"交付"
	if s.begins_with("去") or s.begins_with("回") or s.contains("交付"):
		return State.WALK
	if s.contains("开会") or s.contains("吵"):
		return State.ARGUE
	return State.IDLE          # 兜底（含所有"在…"）


func set_path(p: Array[Vector2i], end: Vector2i) -> void:
	if data.get("brain_down", false):
		stop()
		return
	path = p.duplicate()
	target = Vector2(end) * CELL
	moving = not path.is_empty() or position.distance_to(target) > 0.12


func stop() -> void:
	path.clear()
	moving = false


func grid_pos() -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.y / CELL))


func _physics_process(delta: float) -> void:
	if data.get("brain_down", false):
		stop()
		return
	if not moving:
		return
	state = State.WALK
	var budget := speed * CELL * speed_mul * delta

	while budget > 0.0 and (not path.is_empty() or position.distance_to(target) > 0.12):
		if path.is_empty():
			var to_t := target - position
			var d := to_t.length()
			if d <= budget or d < 0.001:
				position = target
			else:
				position += to_t / d * budget
			budget = 0.0
			break
		var next: Vector2i = path[0]
		var to_n := Vector2(next) * CELL - position
		var dn := to_n.length()
		if dn <= budget or dn < 0.001:
			position = Vector2(next) * CELL
			path.remove_at(0)
			budget -= dn
			step_taken.emit()
		else:
			position += to_n / dn * budget
			budget = 0.0

	if path.is_empty() and position.distance_to(target) <= 0.12:
		position = target
		moving = false
		state = map_state(acting_text)
	queue_redraw()


func _process(delta: float) -> void:
	if data.get("brain_down", false):
		stop()
		pose = _frozen_pose
		if body:
			body.modulate = Color(.55, .55, .60)
		queue_redraw()
		return
	if body:
		body.modulate = Color.WHITE
		body.position = Vector2.ZERO
	if moving:
		pose = "walk"
		_update_dir()
		_anim_t += delta
		if body:
			body.offset = Vector2(-128, -FOOT_IN_TEX)
			body.scale = Vector2.ONE * ART_SCALE
			body.texture = walk_frame(_dir, 1 + int(_anim_t * WALK_FPS) % 2)
	else:
		_anim_t = 0.0
		_idle_t += delta
		pose = activity_name()
		if body:
			if pose in ["type_up", "sit_up", "sit_down", "drink_down"]:
				body.offset = Vector2(-160, -437)
				body.scale = Vector2.ONE * ACTIVITY_SCALE
				var fps: float = float(TYPE_FPS.get(who, 4.0)) if pose == "type_up" else 1.2
				var frame := 1 + int(_idle_t * fps) % 2
				# 等待模型输出时停手，仍然保持坐姿。
				if pose == "sit_up" and not data.get("seated", false):
					frame = 1
				body.texture = activity_frame(pose, frame)
				var seat := rest_seat()
				if pose == "sit_down" and not seat.is_empty():
					# 寻路停在家具前的空格，身体按臀部锚点落在坐垫上。
					body.position = seat["contact"] * CELL - position - (body.offset + SEATED_HIP) * body.scale
			else:
				body.offset = Vector2(-128, -FOOT_IN_TEX)
				body.scale = Vector2.ONE * ART_SCALE
				body.texture = OfficeArt.texture(who + "_idle_" + str(1 + int(_idle_t * 2) % 2))
	queue_redraw()

func activity_frame(activity: String, frame: int) -> Texture2D:
	return OfficeArt.texture(who + "_" + activity + "_" + str(frame))

func activity_name() -> String:
	if moving:
		return "walk"
	var seats := {"m3":Vector2i(31,7), "flash":Vector2i(33,7), "kimi":Vector2i(35,7), "longcat":Vector2i(32,11), "step5":Vector2i(34,11)}
	if data.get("seated", false) and position.distance_to(Vector2(seats[who]) * CELL) < 6:
		return "sit_down" if seats[who].y < 9 else "sit_up"
	if position.distance_to(Vector2(md.spawn[who]) * CELL) < 6:
		return "type_up" if state == State.WORK and data.get("typing", false) else "sit_up"
	if state == State.REST or (data.get("off_today", false) and not moving):
		return "drink_down"
	if not rest_seat().is_empty():
		return "sit_down"
	return "idle"


func rest_seat() -> Dictionary:
	if state != State.SLACK or md == null or not md.rest_seats.has(who):
		return {}
	var seat: Dictionary = md.rest_seats[who]
	return seat if position.distance_to(Vector2(seat["approach"]) * CELL) < 6 else {}


static func _parse_color(c: String) -> Color:
	if Color.html_is_valid(c):
		return Color.html(c)
	return Color("#7DC6FF")


func visual_rect() -> Rect2:
	var rect := Rect2(-31, -63 if pose.begins_with("sit") or pose == "type_up" else -80, 62, 83)
	return Rect2(rect.position + (body.position if body else Vector2.ZERO), rect.size)

func _draw() -> void:
	draw_ellipse_shadow()
	if not show_detail and not data.get("brain_down", false):
		return
	var font := ThemeDB.fallback_font
	var origin := body.position if body else Vector2.ZERO
	var down := bool(data.get("brain_down", false))
	var text := UITheme.ellipsis(str(acting_text), 10)
	var status_bottom := origin + Vector2(0, (-68 if pose.begins_with("sit") or pose == "type_up" else -84) if down else 22)
	UITheme.world_label(self, font, status_bottom, text, 13, UITheme.BAD if down else UITheme.WARN)

func draw_ellipse_shadow() -> void:
	draw_set_transform((body.position if body else Vector2.ZERO) + Vector2(0, 2), 0, Vector2(1, .35))
	draw_circle(Vector2.ZERO, 14, Color(0,0,0,.2))
	draw_set_transform(Vector2.ZERO)
