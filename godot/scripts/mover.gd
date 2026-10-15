class_name Mover
extends Node2D
## 角色沿寻路结果逐点移动。服务器坐标是权威，本地只做插值渲染。

signal arrived()
signal step_taken()          # 每走完一格发一次，M4-2 打字音会挂这里

@export var speed: float = 2.2      # 格/秒
@export var snap_radius: float = 0.12

var md: MapData
var cell: float = 32.0
var path: Array[Vector2i] = []
var target: Vector2 = Vector2.ZERO     # 世界坐标
var moving := false
var speed_mul := 1.0
var blocked := false


func setup(data: MapData, start: Vector2i) -> void:
	md = data
	position = Vector2(start) * cell


func set_path(p: Array[Vector2i], end: Vector2i) -> void:
	path = p.duplicate()
	target = Vector2(end) * cell
	moving = not path.is_empty()
	if path.is_empty() and position.distance_to(target) > snap_radius:
		moving = true   # 最后一小段直线


func stop() -> void:
	path.clear()
	moving = false


func set_speed_mul(m: float) -> void:
	speed_mul = clampf(m, 0.2, 3.0)


func _physics_process(delta: float) -> void:
	if not moving or md == null:
		return
	var step := speed * speed_mul * delta
	var budget := step

	while budget > 0.0 and (not path.is_empty() or position.distance_to(target) > snap_radius):
		if path.is_empty():
			# 尾段：直线走到 target
			var to_t := target - position
			var d := to_t.length()
			if d <= budget or d < 0.001:
				position = target
				budget = 0.0
			else:
				position += to_t / d * budget
				budget = 0.0
			break
		var next: Vector2i = path[0]
		var to_n := Vector2(next) * cell - position
		var dn := to_n.length()
		if dn <= budget or dn < 0.001:
			position = Vector2(next) * cell
			path.remove_at(0)
			budget -= dn
			step_taken.emit()
		else:
			position += to_n / dn * budget
			budget = 0.0

	if path.is_empty() and position.distance_to(target) <= snap_radius:
		position = target
		moving = false
		arrived.emit()


## 目标格是否可通行（客户端做一次校验，避免走进墙里）
func is_reachable_now(p: Vector2i) -> bool:
	return md == null or md.is_passable(p)
