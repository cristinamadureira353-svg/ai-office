class_name BanterUI
extends Control
## 路过吐槽气泡（M2-5 的前端表现）
##
## 后端把最近的吐槽放在 state.banters，这里在屏幕上方依次排开小气泡。
## 只显示"新出现的"——每条按 id 去重，否则每帧轮询都会把旧对话重画一遍。
## 长台词按宽度折行，撑不破气泡（DEV_PLAN M2-9 用例 4）。

const MAX_SHOWN := 3
const BUBBLE_W := 340.0
const PAD := 24.0
const LIFE := 9.0

var _items: Array = []          # {key, who, text, t}
var _seen := {}
var _font: Font
var _meeting_active := false


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(true)


func update_from(d: Dictionary) -> void:
	_meeting_active = not UITheme.dict_of(d, "meeting").is_empty()
	var bs: Array = UITheme.arr_of(d, "banters")
	var added := 0
	for b in bs:
		var lines: Array = b.get("lines", [])
		if lines.is_empty():
			continue
		var key := "%s|%s|%s" % [b.get("worker", ""), b.get("passer", ""),
				str(lines[0].get("text", "")).substr(0, 12)]
		if _seen.has(key):
			continue
		_seen[key] = true
		for ln in lines:
			_items.append({"key": key + str(ln), "who": String(ln.get("who", "")),
					"text": String(ln.get("text", "")), "t": LIFE})
			added += 1
	# 只留最新的几条，顺手清掉去重表防止无限增长
	while _items.size() > MAX_SHOWN * 3:
		_items.pop_front()
		if _seen.size() > 200:
			_seen.clear()
	if added:
		queue_redraw()


func _process(dt: float) -> void:
	if _items.is_empty():
		return
	var changed := false
	for it in _items:
		it["t"] = float(it["t"]) - dt
		if it["t"] <= 0.0:
			changed = true
	_items = _items.filter(func(it): return float(it["t"]) > 0.0)
	if changed or not _items.is_empty():
		queue_redraw()


func visible_bubbles() -> Array:
	var out: Array = []
	if _meeting_active:
		return out
	var y := GameHUD.EVENT_Y + GameHUD.EVENT_H + 16
	var bottom := size.y - 188
	var shown := _items.slice(maxi(0, _items.size() - MAX_SHOWN))
	for it in shown:
		var rows := mini(3, int((bottom - y - PAD * 2 - 24) / 22))
		if rows < 1:
			break
		var lines := UITheme.preview_lines(String(it["text"]), int(BUBBLE_W - PAD * 2), _font, UITheme.SMALL, rows)
		var h := PAD * 2 + 24 + maxf(1, lines.size()) * 22
		out.append({"item":it,"lines":lines,"rect":Rect2(size.x-356,y,BUBBLE_W,h)})
		y += h + 8
	return out

func _draw() -> void:
	for bubble in visible_bubbles():
		var it: Dictionary = bubble.item
		var r: Rect2 = bubble.rect
		var col := UITheme.worker_color(String(it["who"]))
		var a := clampf(float(it["t"]) / 2, 0, 1)
		UITheme.panel(self,r,Color(UITheme.BG.r,UITheme.BG.g,UITheme.BG.b,a*.94),Color(col.r,col.g,col.b,a))
		UITheme.text_in(self,_font,Rect2(r.position+Vector2(PAD,PAD),Vector2(r.size.x-PAD*2,22)),UITheme.name_of(String(it["who"])),UITheme.SMALL,Color(col.r,col.g,col.b,a))
		for i in bubble.lines.size():
			UITheme.text_in(self,_font,Rect2(r.position+Vector2(PAD,PAD+24+i*22),Vector2(r.size.x-PAD*2,22)),bubble.lines[i],UITheme.SMALL,Color(UITheme.TEXT.r,UITheme.TEXT.g,UITheme.TEXT.b,a))
