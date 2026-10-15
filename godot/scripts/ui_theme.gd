class_name UITheme
extends RefCounted
## 全局 UI 风格（DESIGN 9.3）
##
## 所有面板都从这里取色和画边框。这样"风格统一"是代码事实，不是靠每个面板自觉。
## V2 木框、暖色正文、九宫格面板和三态按钮。

const BG := Color("#35201e")          # 面板底
const EDGE := Color("#97572d")        # 1px 边框
const EDGE_HI := Color("#d4a558")    # 悬停/聚焦边框
const TEXT := Color("#f4e6c7")
const TEXT_DIM := Color("#d4c4a4")
const TEXT_FAINT := Color("#bdaa88")
# M4-3：坏档、失败提示用。跟 ACCENT 一样是常量，别在用到处现调 Color()——
# 一屏里两种"红"看着就是两回事。
const DANGER := Color("#e0605c")
const ACCENT := Color("#7DC6FF")
const GOOD := Color("#06D6A0")
const WARN := Color("#FFD166")
const BAD := Color("#FF6B6B")
const ORANGE := Color("#ff9f6b")

const WORKER_COLOR := {
	"m3": Color("#7DC6FF"),
	"flash": Color("#FFD166"),
	"longcat": Color("#06D6A0"),
	"kimi": Color("#B388FF"),
	"step5": Color("#FF6B6B"),
	"boss": Color("#F2F5FA"),
}

const RADIUS := 8.0
const PAD := 24.0
const BODY := 16
const SMALL := 14
const TITLE := 18


static func worker_color(who: String) -> Color:
	return WORKER_COLOR.get(who, Color("#888888"))


static func name_of(who: String) -> String:
	return {"m3": "M3", "flash": "Flash", "longcat": "LongCat",
			"kimi": "Kimi", "step5": "Step5", "boss": "你"}.get(who, who)


static var _skins: Dictionary = {}

static func skin(id: String, border := 42.0) -> StyleBoxTexture:
	if not _skins.has(id):
		var style := StyleBoxTexture.new()
		style.texture = OfficeArt.texture(id)
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			style.set_texture_margin(side, border)
		_skins[id] = style
	return _skins[id]

static func patch(ci: CanvasItem, r: Rect2, id: String, scale := .32, opacity := 1.0) -> void:
	var style := skin(id)
	style.modulate_color = Color(1,1,1,opacity)
	ci.draw_set_transform(Vector2.ZERO, 0, Vector2.ONE * scale)
	ci.draw_style_box(style, Rect2(r.position / scale, r.size / scale))
	ci.draw_set_transform(Vector2.ZERO)

static func panel(ci: CanvasItem, r: Rect2, fill := BG, edge := EDGE, scale := .32) -> void:
	patch(ci, r, "panel", scale, fill.a)
	if edge != EDGE:
		ci.draw_rect(r.grow(-5), Color(edge.r,edge.g,edge.b,.55), false, 1)

static func button(ci: CanvasItem, r: Rect2, hovered := false, enabled := true) -> void:
	var id := "button_normal"
	if hovered:
		id = "button_pressed" if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) else "button_hover"
	patch(ci, r, id, .16, 1.0 if enabled else .45)

static func portrait(ci: CanvasItem, who: String, r: Rect2) -> void:
	if who not in ["m3", "flash", "longcat", "kimi", "step5"]:
		return
	var t := OfficeArt.texture(who + "_portrait")
	var wh := t.get_size() * minf(r.size.x / t.get_width(), r.size.y / t.get_height())
	ci.draw_texture_rect(t, Rect2(r.position + (r.size-wh)*.5, wh), false)

static func bar(ci: CanvasItem, r: Rect2, ratio: float, col: Color) -> void:
	ci.draw_texture_rect(OfficeArt.texture("progress_track"), r, false)
	var width := r.size.x * clampf(ratio, 0, 1)
	if width > .5:
		ci.draw_texture_rect(OfficeArt.texture("progress_fill"), Rect2(r.position,Vector2(width,r.size.y)), false, col)

## 按像素宽度折行。中文没有空格，不能靠空格断行；
## 这里按"能放多少个字符"硬折，够用且不引依赖。
static func wrap(s: String, px: int, font: Font, size: int) -> Array[String]:
	var out: Array[String] = []
	var line := ""
	for i in s.length():
		var ch := s[i]
		if ch == "\r":
			continue
		if ch == "\n":
			out.append(line)
			line = ""
			continue
		if font.get_string_size(line + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > px:
			if not line.is_empty():
				out.append(line)
			line = ch
		else:
			line += ch
	if not line.is_empty():
		out.append(line)
	return out


static func text(ci: CanvasItem, font: Font, pos: Vector2, s: String,
		fs: int, col: Color) -> void:
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## 用实际字体宽度约束单行内容，英文、中文和数字共用同一边界。
static func fit(s: String, width: float, font: Font, fs: int) -> String:
	var line := s.replace("\n", " ").replace("\r", "")
	if font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
		return line
	if font.get_string_size("…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > width:
		return ""
	var low := 0
	var high := line.length()
	while low < high:
		var mid := (low + high + 1) / 2
		if font.get_string_size(line.substr(0, mid) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
			low = mid
		else:
			high = mid - 1
	return line.substr(0, low) + "…"


static func text_in(ci: CanvasItem, font: Font, r: Rect2, s: String,
		fs: int, col: Color, alignment := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var value := fit(s, r.size.x, font, fs)
	var width := font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var x := r.position.x
	if alignment == HORIZONTAL_ALIGNMENT_CENTER:
		x += (r.size.x - width) * .5
	elif alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		x += r.size.x - width
	var y := r.position.y + (r.size.y - font.get_height(fs)) * .5 + font.get_ascent(fs)
	text(ci, font, Vector2(x, y), value, fs, col)


static func button_text(ci: CanvasItem, font: Font, r: Rect2, s: String,
		fs: int, col: Color) -> void:
	text_in(ci, font, r.grow(-9), s, fs, col, HORIZONTAL_ALIGNMENT_CENTER)


static func preview_lines(s: String, width: int, font: Font, fs: int, count: int) -> Array[String]:
	var lines := UITheme.wrap(s, width, font, fs)
	if lines.size() > count:
		lines = lines.slice(0, count)
		lines[-1] = fit(lines[-1] + "…", width, font, fs)
	return lines


static func style_input(input: LineEdit, fs := BODY) -> void:
	input.add_theme_font_override("font", ThemeDB.fallback_font)
	input.add_theme_font_size_override("font_size", fs)
	for state in ["normal", "focus", "read_only"]:
		input.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	input.add_theme_color_override("font_color", TEXT)
	input.add_theme_color_override("font_placeholder_color", TEXT_DIM)


static func world_scale(ci: CanvasItem) -> float:
	var scale := ci.get_global_transform_with_canvas().get_scale().x * ci.get_viewport().get_stretch_transform().get_scale().x
	return maxf(.01, scale / maxf(1.0, DisplayServer.screen_get_scale()))


static func world_font_size(ci: CanvasItem, pixels: int) -> int:
	return maxi(1, int(ceil(pixels / world_scale(ci))))


## 场景标签随镜头缩放补偿字号，全景时也能认出员工和区域。
static func world_label(ci: CanvasItem, font: Font, bottom: Vector2, value: String, pixels: int, color: Color) -> Rect2:
	var fs := world_font_size(ci, pixels)
	var pad := Vector2(5, 2) / world_scale(ci)
	var wh := Vector2(font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, font.get_height(fs)) + pad * 2
	var r := Rect2(bottom - Vector2(wh.x * .5, wh.y), wh)
	ci.draw_rect(r, Color(.16, .10, .07, .88))
	ci.draw_string(font, r.position + pad + Vector2(0, font.get_ascent(fs)), value, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)
	return r


# ── 取值的安全写法 ───────────────────────────────────────────────────────────
# ★不要写 `d.get("x") or {}` —— GDScript 的 or 是**纯布尔运算符**，
#   不是 Python 那种"取第一个真值"。结果是 bool，赋给 Dictionary/Array
#   类型的变量会直接报 "Trying to assign value of type 'bool'"。
static func dict_of(d: Dictionary, key: String) -> Dictionary:
	var v = d.get(key)
	return v if typeof(v) == TYPE_DICTIONARY else {}


static func arr_of(d: Dictionary, key: String) -> Array:
	var v = d.get(key)
	return v if typeof(v) == TYPE_ARRAY else []


static func str_of(d: Dictionary, key: String, def := "") -> String:
	var v = d.get(key)
	return str(v) if v != null and typeof(v) != TYPE_NIL else def


## 超长文本的省略（防撑破布局）
static func ellipsis(s: String, max_chars: int) -> String:
	if s.length() <= max_chars:
		return s
	return s.substr(0, maxi(0, max_chars - 1)) + "…"
