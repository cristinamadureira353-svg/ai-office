class_name SseChat
extends Node
## 老板对话的流式客户端（M2-9）
##
## ★为什么不用 HTTPRequest：它要等整个响应体收完才触发 request_completed，
##   拿不到"逐字出字"。必须用 HTTPClient + StreamPeerTCP 手动轮询 STATUS_BODY，
##   每轮 read_chunk() 把增量喂给 _feed()。
##
## SSE 解析拆成纯函数 parse_line()，这样不用连后端就能单测。

signal started(who)
signal delta(who, text)
signal finished(who, got_text)
signal failed(who, msg)

const HOST := "127.0.0.1"
const PORT := 8850

enum Phase {IDLE, TCP, REQUEST, BODY}

var busy := false
var who := ""
var _phase := Phase.IDLE
var _http: HTTPClient
var _buf := ""
var _got_text := false
var _error_message := ""
var _web_callback
var _web_stream
var _request_id := 0


func _ready() -> void:
	set_process(false)


var _pending_text := ""


## 返回 false 表示上一次还没说完（面板据此禁掉发送）
func send(who_id: String, text: String) -> bool:
	if busy:
		return false
	who = who_id
	_pending_text = text
	_buf = ""
	_got_text = false
	_error_message = ""
	busy = true
	_request_id += 1
	if OS.has_feature("web"):
		_web_stream = JavaScriptBridge.get_interface("AIOfficeStream")
		if _web_stream == null:
			_finish(false, "网页聊天连接尚未就绪")
			return false
		_web_callback = JavaScriptBridge.create_callback(_on_web_event)
		_web_stream.open(_request_id, OfficeArt.api_base() + "/api/chat",
				JSON.stringify({"who": who, "text": text}), _web_callback)
		return true
	_phase = Phase.TCP
	_http = HTTPClient.new()
	var err := _http.connect_to_host(HOST, OfficeArt.backend_port())
	if err != OK:
		busy = false
		_phase = Phase.IDLE
		failed.emit(who_id, "连不上后端（错误 %d）" % err)
		return false
	set_process(true)
	return true


func cancel() -> void:
	if OS.has_feature("web") and _web_stream != null:
		_web_stream.cancel(_request_id)
	_request_id += 1
	if busy and _http:
		_http.close()
	busy = false
	_phase = Phase.IDLE
	set_process(false)


func _on_web_event(args: Array) -> void:
	if args.is_empty() or not busy:
		return
	var packet: Variant = JSON.parse_string(str(args[0]))
	if not packet is Dictionary or int(packet.get("request", -1)) != _request_id:
		return
	if packet.get("error"):
		_finish(false, "这次没连上，稍后再试")
		return
	_feed(str(packet.get("data", "")))
	if busy and packet.get("end", false):
		_finish(_got_text)


func _process(_d: float) -> void:
	if not busy:
		return
	_http.poll()
	var st := _http.get_status()
	match st:
		HTTPClient.STATUS_CONNECTED:
			if _phase == Phase.TCP:
				_send_request()
		HTTPClient.STATUS_BODY:
			_phase = Phase.BODY
			_read()
		HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, \
		HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, \
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_finish(false)
		_:
			pass


func _send_request() -> void:
	# JSON.stringify 会自己处理引号和转义，不要再手动拼
	var body := JSON.stringify({"who": who, "text": _pending_text})
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Accept: text/event-stream",
	])
	var err := _http.request(HTTPClient.METHOD_POST, "/api/chat", headers, body)
	if err != OK:
		_finish(false, "请求发不出去（错误 %d）" % err)
		return
	_phase = Phase.REQUEST


func _read() -> void:
	while _http.get_status() == HTTPClient.STATUS_BODY:
		var chunk: PackedByteArray = _http.read_chunk()
		if chunk.is_empty():
			break
		_feed(chunk.get_string_from_utf8())
		if not busy:
			return
	if _http.get_status() == HTTPClient.STATUS_DISCONNECTED or \
			not _http.has_response():
		_finish(_got_text)


func _feed(s: String) -> void:
	_buf += s
	# SSE 以空行分事件；后端用 \n\n
	while true:
		var idx := _buf.find("\n\n")
		if idx < 0:
			break
		var block := _buf.substr(0, idx)
		_buf = _buf.substr(idx + 2)
		for raw in block.split("\n"):
			var ev := parse_line(raw)
			if ev.is_empty():
				continue
			var t := String(ev.get("type", ""))
			if t == "start":
				started.emit(String(ev.get("who", who)))
			elif t == "delta":
				_got_text = true
				delta.emit(who, String(ev.get("text", "")))
			elif t == "error":
				_error_message = String(ev.get("message", "出错了"))
			elif t == "finish":
				_finish(_got_text)
				return


## 纯函数：解析一行 SSE。返回 {} 表示不是事件行（注释、空行、心跳）。
static func parse_line(raw: String) -> Dictionary:
	var line := raw.strip_edges()
	if line.is_empty() or not line.begins_with("data:"):
		return {}
	var payload := line.substr(5).strip_edges()
	if payload.is_empty() or payload == "[DONE]":
		return {}
	# JSON.parse_string 返回 Variant，不能用 := 推断（会被当 Variant 警告）
	var j: Variant = JSON.parse_string(payload)
	if typeof(j) != TYPE_DICTIONARY:
		return {}
	return j


func _finish(ok: bool, msg := "") -> void:
	var w := who
	if not _error_message.is_empty():
		ok = false
		msg = _error_message
	cancel()
	if ok:
		finished.emit(w, true)
	else:
		failed.emit(w, msg if msg != "" else "没收到回复")
