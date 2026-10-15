class_name RelationPanel
extends Control
## 关系网可视化：5×5 矩阵，色块深浅 = 好感高低。
## M2-3 的"看得见"部分。玩家能看出谁跟谁不对付。

const COLORS := {
	"m3": "#7DC6FF", "flash": "#FFD166", "longcat": "#06D6A0",
	"kimi": "#B388FF", "step5": "#FF6B6B",
}
const SHORT := {"m3": "M3", "flash": "Fl", "longcat": "LC", "kimi": "Km", "step5": "S5"}
const ORDER := ["m3", "flash", "longcat", "kimi", "step5"]

var rel: Dictionary = {}
var _font: Font
var _open := false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func update_from(d: Dictionary) -> void:
	var r = d.get("relations")
	if r is Dictionary:
		rel = r
		queue_redraw()


func _draw() -> void:
	if rel.is_empty():
		return
	var r := _panel_rect()
	var x := r.position.x
	var y := r.position.y
	var cell := 34.0

	# 折叠时只显示标题条
	if not _open:
		return

	UITheme.panel(self, r, UITheme.BG, UITheme.ACCENT)
	UITheme.text_in(self, _font, Rect2(x + 24, y + 24, 140, 20), "关系网", 12, UITheme.TEXT)
	UITheme.text_in(self, _font, Rect2(r.end.x - 64, y + 24, 40, 20), "[Tab]", 10, UITheme.TEXT_DIM)

	var gx := x + 60.0
	var gy := y + 76.0
	# 列头
	for ci in ORDER.size():
		UITheme.text_in(self, _font, Rect2(gx + ci * cell, gy - 24, cell, 18), SHORT[ORDER[ci]], 10, Color(COLORS[ORDER[ci]]), HORIZONTAL_ALIGNMENT_CENTER)
	# 行头 + 格
	for ri in ORDER.size():
		UITheme.text_in(self, _font, Rect2(x + 24, gy + ri * cell, 28, cell), SHORT[ORDER[ri]], 10, Color(COLORS[ORDER[ri]]), HORIZONTAL_ALIGNMENT_CENTER)
		for ci in ORDER.size():
			var a: String = ORDER[ri]
			var b: String = ORDER[ci]
			if a == b:
				draw_rect(Rect2(gx + ci * cell + 2, gy + ri * cell + 2, cell - 4, cell - 4),
						Color(0.12, 0.14, 0.19))
				continue
			var box := Rect2(gx + ci * cell + 2, gy + ri * cell + 2, cell - 4, cell - 4)
			# 底框：0（中立）也画出来，否则"中立"和"没数据"看起来一样
			draw_rect(box, Color(0.12, 0.14, 0.19))
			draw_rect(box, Color(0.20, 0.23, 0.30), false, 1.0)
			var v: float = float(rel.get("%s→%s" % [a, b], 0.0))
			var t: float = clampf(absf(v) / 100.0, 0.0, 1.0)
			if absf(v) > 0.5:
				# 正=绿 负=红，越深越强
				var col := Color("#06d6a0") if v >= 0 else Color("#ff6b6b")
				col = col.lerp(Color(0.12, 0.14, 0.19), 1.0 - t)
				draw_rect(box, col)
			if t > 0.35:
				UITheme.text_in(self, _font, box.grow(-2), "%d" % int(round(v)), 9, Color(1, 1, 1, 0.8), HORIZONTAL_ALIGNMENT_CENTER)


func toggle() -> void:
	_open = not _open
	queue_redraw()


func _panel_rect() -> Rect2:
	return Rect2(24, size.y - 172 - 16 - 268, 264, 268)
