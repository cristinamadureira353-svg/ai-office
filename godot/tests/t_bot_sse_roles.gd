extends SceneTree
## 回归 t_bot_sse_roles：用户自己的消息不能被当成 Bot 回复。
##
## 真实 bug（bot_sse.gd _handle_frame）：服务端会先把用户那句话（role=user）
## 写库再广播 message.upsert。通道原来不过滤 role ⇒ 用户消息被当成 Bot 回复显示，
## 它的长度还会顶掉全文游标 _seen，让真回复的开头丢失，status=done 更会让气泡
## 提前收尾。修法是 `if String(m.get("role", "")) != "bot": return`。
##
## 这里只喂帧、不建立真实连接：bot_id 直接赋值。watch() 会真的去连
## 127.0.0.1:/api/events，连接建立不属于这条回归的范围。

var passed := 0
var failed := 0
var deltas: Array = []
var finished_status: Array = []


func check(label: String, ok: bool) -> void:
	if ok:
		passed += 1
		print("PASS ", label)
	else:
		failed += 1
		print("FAIL ", label)


func _on_delta(text: String) -> void:
	deltas.append(text)


func _on_finished(status: String) -> void:
	finished_status.append(status)


## 拼一条完整 SSE 事件：_feed 以空行分事件，parse_line 只认 data: 行。
func frame(payload: Dictionary) -> String:
	return "data: " + JSON.stringify(payload) + "\n\n"


## 一个 message.upsert 帧。注意 message.text 是「到目前为止的全文」，不是增量。
func upsert(role: String, text: String, status: String) -> String:
	return frame({
		"type": "message.upsert",
		"chatId": "bot:testbot",
		"message": {"role": role, "text": text, "status": status},
	})


func _init() -> void:
	await process_frame
	var sse := BotSse.new()
	root.add_child(sse)
	await process_frame
	sse.bot_id = "testbot"
	sse.delta.connect(_on_delta)
	sse.finished.connect(_on_finished)

	# ① 用户自己发的话（role=user）：既不显示成回复，也不能动全文游标。
	sse._feed(upsert("user", "你好", "done"))
	check("用户消息不发射 delta", deltas.is_empty())
	check("用户消息不发射 finished", finished_status.is_empty())
	check("用户消息不推进全文游标 _seen", sse._seen == 0)

	# ② 真正的 Bot 回复第一帧：游标还停在 0，应当整段出字。
	sse._feed(upsert("bot", "我很好", "streaming"))
	check("Bot 首帧 delta 发射全文", deltas == ["我很好"])
	check("status=streaming 不结束气泡", finished_status.is_empty())

	# ③ 同一段回复的后续帧：text 是全文 ⇒ 只能发射新增的那一段。
	sse._feed(upsert("bot", "我很好，谢谢", "done"))
	check("后续帧只发射增量而不是整段", deltas == ["我很好", "，谢谢"])
	check("status=done 时结束气泡", finished_status == ["done"])

	print("BOT SSE ROLES: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
