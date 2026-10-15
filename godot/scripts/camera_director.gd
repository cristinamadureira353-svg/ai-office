class_name CameraDirector
extends Node2D
## 主视图给右侧信息栏和底部员工卡留出空间；Q/E 聚焦，O 回全景。
const REGIONS := {"lobby":{"focus":"reception","label":"大堂"},"office":{"focus":"desk","label":"办公区"},"meeting":{"focus":"meeting","label":"会议室"}}
const REGION_ORDER := ["lobby","office","meeting"]
var cam: Camera2D
var md: MapData
var current := 1
var _region_idx := 1
var _moving := false
var overview := true
var _goal := Vector2.ZERO
var _zoom := 1.0

func setup(data: MapData) -> void:
	md = data
	cam = Camera2D.new()
	cam.name = "Camera"
	cam.limit_left = -100000
	cam.limit_top = -100000
	cam.limit_right = 100000
	cam.limit_bottom = 100000
	add_child(cam)
	get_viewport().size_changed.connect(show_overview)
	show_overview()

func view_rect() -> Rect2:
	var vp := get_viewport_rect().size
	return Rect2(24, 94, maxf(400, vp.x - 424), maxf(300, vp.y - 282))

func _focus_world(region: String) -> Vector2:
	var point := Vector2(md.loc_pos(REGIONS[region]["focus"]))
	# 会议室聚焦座位，给上排角色的头部留出顶栏下方的空间。
	if region == "meeting":
		point.y -= 4
	return point * OfficeArt.CELL

func _configure(focus: Vector2, zoom: float, snap: bool) -> void:
	var vp := get_viewport_rect().size
	_zoom = zoom
	_goal = focus + (vp * .5 - view_rect().get_center()) / zoom
	if snap:
		cam.position = _goal
		cam.zoom = Vector2.ONE * _zoom
		_moving = false
	else:
		_moving = true

func show_overview() -> void:
	if cam == null or md == null:
		return
	overview = true
	var world := Vector2(md.grid_w, md.grid_h) * OfficeArt.CELL
	var usable := view_rect().size
	_configure(world * .5, minf(usable.x / world.x, usable.y / world.y), true)

func region_name() -> String:
	return "全景" if overview else REGIONS[REGION_ORDER[_region_idx]]["label"]

func switch_region(dir: int = 1) -> void:
	_region_idx = (_region_idx + dir + REGION_ORDER.size()) % REGION_ORDER.size()
	go_to(REGION_ORDER[_region_idx])

func go_to(region: String) -> void:
	if not REGIONS.has(region):
		return
	_region_idx = REGION_ORDER.find(region)
	overview = false
	_configure(_focus_world(region) + Vector2(0, 60), 1.4, false)

func go_to_client() -> void:
	# 全景已经能看见客户；放大查看时才切到接待区。
	if not overview:
		go_to("lobby")

func snap_to(region: String) -> void:
	go_to(region)
	cam.position = _goal
	cam.zoom = Vector2.ONE * _zoom
	_moving = false

func _process(delta: float) -> void:
	if not _moving or cam == null:
		return
	cam.position = cam.position.lerp(_goal, clampf(delta * 6, 0, 1))
	cam.zoom = cam.zoom.lerp(Vector2.ONE * _zoom, clampf(delta * 6, 0, 1))
	if cam.position.distance_to(_goal) < .2 and absf(cam.zoom.x - _zoom) < .002:
		cam.position = _goal
		cam.zoom = Vector2.ONE * _zoom
		_moving = false
