class_name BackendLink
extends Node
## 后端通信层。轮询 /api/state，把状态推给场景。
## 连接失败只降级不崩溃（DEV_PLAN M1-4 通过标准第 4 条）。

const STATE_URL := "http://127.0.0.1:8850/api/state"
const COMMAND_URL := "http://127.0.0.1:8850/api/command"

@export var interval: float = 0.4
@export var host: String = "127.0.0.1"
@export var port: int = 8850

var connected := false
var last_version: int = -1
var last_tick: int = -1
var state: Dictionary = {}
var error_count := 0

var _timer: Timer
var _busy := false
var _busy_since := 0
const BUSY_TIMEOUT_MS := 8000

signal state_updated(new_state: Dictionary)
signal connection_changed(is_connected: bool)
signal command_done(ok: bool, msg: String)
signal judgement_done(client_id: String, ok: bool, msg: String)


func _ready() -> void:
	host = "127.0.0.1"
	port = OfficeArt.backend_port()
	_timer = Timer.new()
	_timer.wait_time = interval
	_timer.autostart = true
	_timer.timeout.connect(_poll)
	add_child(_timer)


func _set_connected(v: bool) -> void:
	if connected == v:
		return
	connected = v
	connection_changed.emit(v)
	print("[BACKEND] 连接状态 → ", "已连接" if v else "断开")


func _poll() -> void:
	if _busy:
		# ★ 超时保护：_busy 只有 _on_done 会清。若请求卡住（连接被拒但无回调、
		#   后端半死等），客户端会永久停止轮询 —— 这在真机上同样会发生。
		if Time.get_ticks_msec() - _busy_since > BUSY_TIMEOUT_MS:
			push_warning("轮询超时 %dms，强制释放" % BUSY_TIMEOUT_MS)
			_busy = false
			_set_connected(false)
		return
	_busy = true
	_busy_since = Time.get_ticks_msec()
	var http := HTTPRequest.new()
	http.timeout = 5.0
	add_child(http)
	http.request_completed.connect(_on_done.bind(http))
	var err: Error = http.request(OfficeArt.api_base() + "/api/state")
	if err != OK:
		http.queue_free()
		_busy = false
		_set_connected(false)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: Node = null) -> void:
	# bind() 把 http 追加在信号参数之后，所以它排在第 5 位。
	# 少了这个默认参数，信号分发会报 "expected 4 arguments, but called with 5"。
	_busy = false
	if http != null:
		http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		error_count += 1
		_set_connected(false)
		return
	var txt := body.get_string_from_utf8()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		error_count += 1
		_set_connected(false)
		return
	var d: Dictionary = parsed
	# 契约版本不匹配 → 明确报错，不静默用错格式
	if int(d.get("version", -1)) != 1:
		push_error("后端契约版本不匹配：期望 1，收到 %s" % str(d.get("version")))
		_set_connected(false)
		return

	_set_connected(true)
	var changed := d != state
	state = d
	var v := int(d.get("version", -1))
	var t := int(d.get("tick", -1))
	if v != last_version or t != last_tick or changed:
		last_version = v
		last_tick = t
		state_updated.emit(d)


## 发一条玩家指令
func send_command(who: String, action: String, arg = null, approved: bool = true, kind: String = "") -> void:
	var payload := {"who": who, "action": action, "arg": arg, "approved": approved}
	if action == "judge":
		payload["kind"] = kind
	var body := JSON.stringify(payload)
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(r, c, _h, b):
		print("[BACKEND] command %s/%s → %d %s" % [who, action, c, b.get_string_from_utf8().left(80)])
		var reply: Variant = JSON.parse_string(b.get_string_from_utf8()) if c == 200 else null
		var ok := reply is Dictionary and bool(reply.get("ok", false))
		var msg: String = str(reply.get("msg", "指令完成" if ok else "指令失败")) if reply is Dictionary else "指令未送达，请检查后端连接"
		command_done.emit(ok, msg)
		if action == "judge":
			judgement_done.emit(str(arg), ok, msg)
		http.queue_free())
	var err := http.request(OfficeArt.api_base() + "/api/command",
			["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		command_done.emit(false, "指令未送达，请检查后端连接")
		if action == "judge":
			judgement_done.emit(str(arg), false, "指令未送达，请检查后端连接")


## ── M4-3 存档 ────────────────────────────────────────────────────────────
signal saves_loaded(list_data)
signal save_done(ok, msg)
var _settling := false

func api_newday() -> void:
	if _settling:
		return
	_settling = true
	_post_json("/api/newday", {}, func(_code, result, _text):
		_settling = false
		command_done.emit(bool(result.get("ok", false)), "每日结算已保存" if result.get("ok", false) else "结算失败，请检查连接"))

func _post_json(path: String, body: Dictionary, cb: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	http.request_completed.connect(func(r, c, _h, b):
		var txt: String = b.get_string_from_utf8()
		var d: Dictionary = {}
		if c == 200:
			var j: Variant = JSON.parse_string(txt)
			if typeof(j) == TYPE_DICTIONARY:
				d = j
		if cb.is_valid():
			cb.call(c, d, txt)
		http.queue_free())
	var err := http.request(OfficeArt.api_base() + path,
			["Content-Type: application/json"], HTTPClient.METHOD_POST,
			JSON.stringify(body))
	if err != OK:
		save_done.emit(false, "请求发不出去（错误码 %d）" % err)
		http.queue_free()


func api_save(save_name: String) -> void:
	_post_json("/api/save", {"name": save_name},
		func(c, d, _t): save_done.emit(bool(d.get("ok", false)),
				String(d.get("msg", "存档失败（HTTP %d）" % c))))


func api_load(save_id: String) -> void:
	# 读档后端会停主循环再重启，前端下一次轮询自然就跟上；
	# 这里只回执结果，真正的状态刷新交给 _on_state。
	_post_json("/api/load", {"id": save_id},
		func(c, d, _t): save_done.emit(bool(d.get("ok", false)),
				String(d.get("msg", "读档失败（HTTP %d）" % c))))


func api_saves() -> void:
	var http := HTTPRequest.new()
	http.timeout = 10.0
	add_child(http)
	http.request_completed.connect(func(r, c, _h, b):
		var j: Variant = JSON.parse_string(b.get_string_from_utf8())
		if c == 200 and typeof(j) == TYPE_DICTIONARY:
			saves_loaded.emit(j.get("saves", []))
		else:
			saves_loaded.emit([])
		http.queue_free())
	var err := http.request(OfficeArt.api_base() + "/api/saves")
	if err != OK:
		saves_loaded.emit([])
		http.queue_free()


## 坐标 → 本地格子（后端坐标即格坐标）
func grid_of(d: Dictionary) -> Vector2i:
	return Vector2i(int(round(float(d.get("x", 0)))), int(round(float(d.get("y", 0)))))
