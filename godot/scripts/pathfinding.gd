class_name Pathfinding
extends RefCounted
## 网格 BFS 寻路。26×15=390 格，无需 A*。
## 后端 game.py 里的 bfs_path 是同一套逻辑，GDScript 版本供客户端预测路径。

const DIRS := [Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 0), Vector2i(-1, 0)]


static func manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)


## 返回从 start 到 end 的路径（不含 start，含 end）。不可达返回空数组。
static func find_path(md: MapData, start: Vector2i, end: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	if start == end:
		return path
	if not md.is_passable(end) or not md.is_passable(start):
		return path

	var prev := {start: null}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for d in DIRS:
			var nxt: Vector2i = cur + d
			if prev.has(nxt) or not md.is_passable(nxt):
				continue
			prev[nxt] = cur
			if nxt == end:
				# 回溯
				var node: Variant = nxt
				while node != null:
					path.append(node)
					node = prev[node]
				path.reverse()
				# 去掉起点
				if path.size() > 0:
					path.remove_at(0)
				return path
			queue.append(nxt)
	return path


## 路径总长度（含尾段到 end 的直线距离），用于移动计时
static func path_length(path: Array[Vector2i], end: Vector2i) -> float:
	if path.is_empty():
		return 0.0
	var total := 0.0
	for i in range(path.size() - 1):
		total += Vector2(path[i]).distance_to(Vector2(path[i + 1]))
	if path.size() > 0:
		total += Vector2(path[path.size() - 1]).distance_to(Vector2(end))
	return total
