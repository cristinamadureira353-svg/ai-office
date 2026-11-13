class_name BotSse
extends Node
## 真实 Bot 回复的订阅通道（GET /api/events）。
##
## 只做一件事：按 chatId 过滤出某一个 Bot 的消息帧，把「到目前为止的全文」
## 换算成增量文本抛出去；status 到 done/error 时抛 finished，由上层结束气泡。
## 断线自动重连（有次数上限），始终拿不到流就抛 dropped，同样由上层收尾。
##
## ★为什么不用 HTTPRequest：它要等整个响应体收完才触发 request_completed，
##   拿不到逐字出字。桌面版必须用 HTTPClient 手动轮询 STATUS_BODY，每轮
##   read_chunk() 把增量喂给 _feed()（与 sse_chat.gd 同一套打法）；网页版没有
##   原生 TCP，改走注入的 AIOfficeStream 桥订阅 GET /api/events（白名单路由，
##   见 stream.js）。两条路径的帧都进同一个 _feed()，所以下面的全文去重、
##   断线重连策略对桌面版和网页版完全一致。
##
## ★message.text 是「到目前为止的全文」而不是增量：记住已推送的长度，
##   只推新增部分，否则每一帧都会把整段回复重复刷一遍。

signal delta(text: String)
signal finished(status: String)
signal dropped(msg: String)

const RECONNECT_DELAY := 1.5   # 断线后等多久再连（秒）
const MAX_TRIES := 3           # 拿不到流最多尝试几次，超过就 dropped

enum Phase {IDLE, TCP, REQUEST, BODY}

var bot_id := ""

var _http: HTTPClient
var _phase := Phase.IDLE
var _buf := ""
var _seen := 0          # 已经推送过的字符数（全文去重）
var _tries := 0         # 当前 watch 期间失败的次数
var _retry_at := 0      # 到点再重连（ms）；0 表示没有排队中的重连
var _web_stream = null     # 网页版的 AIOfficeStream 桥（sse_chat.gd 同一套）
var _web_callback = null   # 桥的回调引用，存着防止被 GC
var _request_id := 0       # 桥用请求号区分每次 open


func _ready() -> void:
	set_process(false)


## 开始关心某个 Bot 的回复。连接还热着就只回去重计数，不拆连接。
func watch(new_bot_id: String) -> void:
	if new_bot_id.is_empty():
		return
	# 「热」的判断分平台：桌面看 HTTP 进没进 BODY，网页看桥有没有在跑。
	var warm := bot_id == new_bot_id and _streaming()
	bot_id = new_bot_id
	_seen = 0
	_tries = 0
	_retry_at = 0
	if warm:
		return
	_connect()


## 不再关心任何 Bot（换人、关面板、回复结束）。连接一起收掉。
func unwatch() -> void:
	bot_id = ""
	_seen = 0
	_retry_at = 0
	_disconnect()


func _connect() -> void:
	_disconnect()
	_buf = ""
	_phase = Phase.TCP
	if OS.has_feature("web"):
		# 网页版没有原生 TCP：走注入的 AIOfficeStream 桥，帧照样进 _feed()。
		_connect_web()
		return
	_http = HTTPClient.new()
	var err := _http.connect_to_host("127.0.0.1", OfficeArt.backend_port())
	if err != OK:
		_give_up_or_retry()
		return
	set_process(true)


## 流是否已经建立（桌面看 HTTP 状态，网页看桥有没有在跑）。
func _streaming() -> bool:
	if OS.has_feature("web"):
		return _web_stream != null
	return _http != null and _phase == Phase.BODY


## 网页版：经 AIOfficeStream 桥订阅 GET /api/events（白名单路由，见 stream.js）。
func _connect_web() -> void:
	_web_stream = JavaScriptBridge.get_interface("AIOfficeStream")
	if _web_stream == null:
		# 桥没注入（在 MiniApp iframe 外直接打导出页）：重连也没用，明说。
		dropped.emit("网页聊天连接尚未就绪")
		return
	_request_id += 1
	_web_callback = JavaScriptBridge.create_callback(_on_web_event)
	# body 传空串：这条路由是 GET，没有请求体。
	_web_stream.open(_request_id, OfficeArt.api_base() + "/api/events", "", _web_callback)


## 桥的回调：data 帧喂给和桌面版同一个 _feed()，end/error 走同一套收尾。
func _on_web_event(args: Array) -> void:
	if args.is_empty() or bot_id.is_empty():
		return
	var packet: Variant = JSON.parse_string(str(args[0]))
	if not packet is Dictionary or int(packet.get("request", -1)) != _request_id:
		return
	if packet.get("error"):
		# 桥这一侧 fetch 失败（断网 / CORS）：与桌面版连不上同等对待。
		_give_up_or_retry()
		return
	_feed(str(packet.get("data", "")))
	if bot_id.is_empty():
		# 这一包里已经拿到 done/error，上层收了通道（unwatch），不用再管 end。
		return
	if packet.get("end", false):
		# 长连接被关掉：等价于桌面版的 DISCONNECTED，退避重连；次数用完抛 dropped。
		_give_up_or_retry()


func _disconnect() -> void:
	set_process(false)
	if _http != null:
		_http.close()
		_http = null
	if _web_stream != null:
		# 桥上还在跑的那次 open 一并取消，别让旧帧继续进来。
		_web_stream.cancel(_request_id)
		_web_stream = null
	_phase = Phase.IDLE


## 连不上/断了：退避重试；次数用完就告诉上层「没戏了」，别让气泡一直转。
func _give_up_or_retry() -> void:
	_disconnect()
	_tries += 1
	if _tries >= MAX_TRIES:
		dropped.emit("连不上回复通道，稍后再试")
		return
	_retry_at = Time.get_ticks_msec() + int(RECONNECT_DELAY * 1000.0)
	set_process(true)


func _process(_d: float) -> void:
	if bot_id.is_empty():
		set_process(false)
		return
	if _retry_at > 0:
		if Time.get_ticks_msec() >= _retry_at:
			_retry_at = 0
			_connect()
		return
	if _http == null:
		return
	_http.poll()
	var st := _http.get_status()
	match st:
		HTTPClient.STATUS_CONNECTED:
			if _phase == Phase.TCP:
				_send_request()
		HTTPClient.STATUS_BODY:
			_phase = Phase.BODY
			_tries = 0
			_read()
		HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, \
		HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, \
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			_give_up_or_retry()
		_:
			pass


func _send_request() -> void:
	# 服务端一接上先发 data: {"type":"hello"}，之后才是各事件帧。
	var err := _http.request(HTTPClient.METHOD_GET, "/api/events",
			PackedStringArray(["Accept: text/event-stream"]))
	if err != OK:
		_give_up_or_retry()
		return
	_phase = Phase.REQUEST


func _read() -> void:
	while _http != null and _http.get_status() == HTTPClient.STATUS_BODY:
		var chunk: PackedByteArray = _http.read_chunk()
		if chunk.is_empty():
			break
		_feed(chunk.get_string_from_utf8())


func _feed(s: String) -> void:
	if bot_id.is_empty():
		return
	_buf += s
	# SSE 以空行分事件；服务端用 \n\n（": ping" 心跳不是 data: 行，parse_line 会忽略）。
	while true:
		var idx := _buf.find("\n\n")
		if idx < 0:
			break
		var block := _buf.substr(0, idx)
		_buf = _buf.substr(idx + 2)
		for raw in block.split("\n"):
			var frame := parse_line(raw)
			if not frame.is_empty():
				_handle_frame(frame)


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


func _handle_frame(frame: Dictionary) -> void:
	if String(frame.get("type", "")) != "message.upsert":
		return
	if String(frame.get("chatId", "")) != "bot:" + bot_id:
		return
	var message = frame.get("message")
	if not (message is Dictionary):
		return
	var m: Dictionary = message
	# 只认 Bot 自己的回复帧。服务端会先把用户那句话（角色为 user）写库再广播
	# message.upsert（bot_bridge.mjs:929-930），不过滤就会把用户消息当回复显示、
	# 并且用它的长度顶掉 _seen 让真回复开头丢失、还会因 status=done 提前收尾。
	if String(m.get("role", "")) != "bot":
		return
	var full := String(m.get("text", ""))
	# ★text 是「到目前为止的全文」而不是增量：只推新增部分，
	#   否则每一帧都会把整段回复重复刷一遍。
	if full.length() > _seen:
		delta.emit(full.substr(_seen))
	_seen = full.length()
	var status := String(m.get("status", ""))
	if status == "done" or status == "error":
		finished.emit(status)
