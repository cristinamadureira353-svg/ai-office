extends SceneTree
## M2-7 老板对话面板验证（T1）
##
## 覆盖 DEV_PLAN M2-7 的客户端用例 5、6：
##   5. 200 字限制：超了发送按钮禁用
##   6. 流式 UI：气泡逐字出现，不是一次性跳出
## 外加换人不清空、历史保留等。

var passed := 0
var failed := 0
var panel: ChatPanel
var sent: Array = []


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _cum(pieces: Array) -> Array:
	var out: Array = []
	var n := 0
	for p in pieces:
		n += str(p).length()
		out.append(n)
	return out


func _strictly_increasing(a: Array) -> bool:
	for i in range(1, a.size()):
		if a[i] <= a[i - 1]:
			return false
	return a.size() == 0 or a[0] > 0


func _init() -> void:
	await process_frame
	panel = ChatPanel.new()
	get_root().add_child(panel)
	panel.send_requested.connect(func(w, t): sent.append([w, t]))
	await process_frame

	print("── 1 面板基本行为 ──")
	panel.open_with("m3")
	check("1. 打开后可见且知道在跟谁聊", panel.visible and panel.who == "m3")
	check("1b. 打开时草稿是空的", panel.draft.is_empty())
	check("1c. 空白时不能发", not panel.can_send())
	panel.close()
	check("1d. 关闭后不可见", not panel.visible)

	# ── 2 客户端 200 字限制（DEV_PLAN 用例 5）──
	print("── 2 客户端 200 字限制 ──")
	panel.open_with("m3")
	panel.set_draft("好")
	check("2. 有内容时可以发", panel.can_send())
	panel.set_draft("   ")
	check("2b. 纯空格不能发", not panel.can_send())

	panel.set_draft("啊".repeat(200))
	check("2c. ★正好 200 字可以发", panel.can_send(),
			"剩余 %d" % panel.remaining())
	check("2d. 剩余字数算对", panel.remaining() == 0, str(panel.remaining()))

	panel.set_draft("啊".repeat(201))
	check("2e. ★201 字发不出去", not panel.can_send(),
			"剩余 %d" % panel.remaining())
	check("2f. over_limit 判定正确", panel.over_limit())
	check("2g. 超限时剩余显示为负（UI 会变红）", panel.remaining() < 0,
			str(panel.remaining()))

	# ★粘贴绕过：LineEdit.max_length 挡的是"打字"，粘贴/程序化赋值能塞进去
	panel.set_draft("啊".repeat(5000))
	check("2h. ★粘贴 5000 字也发不出去（max_length 挡不住，只能自己判）",
			not panel.can_send(), str(panel.remaining()))

	# ── 3 流式气泡（DEV_PLAN 用例 6）──
	print("── 3 流式气泡逐字出现 ──")
	panel.set_draft("")
	panel.push_user("在干嘛呢")
	panel.begin_stream()
	check("3. begin_stream 后只有一个新气泡",
			panel.bubbles.size() == 2, str(panel.bubbles.size()))
	check("3b. 正在流式", panel.streaming)

	var pieces := ["在", "摸", "鱼", "呢", "，", "老板"]
	var sizes: Array = []
	var acc := 0
	for piece in pieces:
		panel.push_delta(piece)
		acc += piece.length()
		sizes.append(panel.bubbles[-1]["text"].length())
	check("3c. ★流式期间**始终只有一个 AI 气泡**（没有刷出一排碎句）",
			panel.bubbles.size() == 2, str(panel.bubbles.size()))
	# 期望值从分片自己累加，别硬编码 —— 中文一个字就是一个 length，
	# "老板"是两字，硬写 [...,6] 会平白判失败。
	check("3d. ★气泡文本是逐片变长的（严格递增且等于累加）",
			sizes == _cum(pieces) and _strictly_increasing(sizes),
			"实测 %s 期望 %s" % [sizes, _cum(pieces)])
	check("3e. 6 片拼起来是对的",
			panel.bubbles[-1]["text"] == "在摸鱼呢，老板",
			panel.bubbles[-1]["text"])

	panel.end_stream()
	check("3f. 结束后不在流式", not panel.streaming)
	check("3g. 气泡标记为已完成", panel.bubbles[-1]["done"] == true)

	# 再来一轮：不能复用上一轮的气泡
	panel.begin_stream()
	panel.push_delta("在的")
	check("3h. 第二轮起的是新气泡", panel.bubbles.size() == 3,
			str(panel.bubbles.size()))
	check("3i. 新气泡从空开始", panel.bubbles[-1]["text"] == "在的")
	panel.end_stream()

	# 没 begin_stream 就 push：应该自己兜住，而不是往用户气泡里追加
	var before: String = panel.bubbles[-1]["text"]
	panel.end_stream()
	panel.streaming = false
	panel.push_delta("漏了 begin")
	check("3j. ★没 begin_stream 就来 delta 也不会写错气泡",
			panel.bubbles[-1]["text"] != before, "写到了上一条")

	# ── 4 历史与发送 ──
	print("── 4 历史保留与发送 ──")
	panel.open_with("kimi")
	check("4. 换人后历史还在（不串台）", panel.bubbles.size() >= 3,
			str(panel.bubbles.size()))
	check("4a. 换到新员工不显示其他人的历史", panel._message_layout().is_empty())
	panel.set_draft("你今天状态怎么样")
	sent.clear()
	panel._on_submit("你今天状态怎么样")
	check("4b. 提交后清空草稿", panel.draft.is_empty())
	check("4c. ★提交发出信号（who + 文本）",
			sent.size() == 1 and sent[0][0] == "kimi"
			and sent[0][1] == "你今天状态怎么样", str(sent))
	check("4d. 用户消息进了气泡区",
			panel.bubbles[-1]["who"] == "boss", str(panel.bubbles[-1]))

	sent.clear()
	panel.set_draft("啊".repeat(300))
	panel._on_submit("啊".repeat(300))
	check("4e. ★超长内容提交不出去（前端也挡一道）", sent.is_empty(), str(sent))
	panel.set_draft("")
	panel.begin_stream()
	panel.push_delta("这是 Kimi 的回复")
	panel.end_stream()
	check("4f. 当前员工只能看到自己的两条消息", panel._message_layout().size() == 2)
	panel.open_with("m3")
	var own_history := panel._message_layout()
	var other_reply := false
	for message in own_history:
		for line in message.lines:
			other_reply = other_reply or line.contains("这是 Kimi 的回复")
	check("4g. 回到原员工保留历史且不出现别人的回复", own_history.size() >= 3 and not other_reply)

	# ── 5 上限常量与后端一致 ──
	print("── 5 常量一致性 ──")
	check("5. MAX_CHARS 是 200（与后端 CHAT_MAX_CHARS 一致）",
			ChatPanel.MAX_CHARS == 200, str(ChatPanel.MAX_CHARS))
	check("5b. 五个角色都有配色和名字",
			ChatPanel.COLORS.size() == 6 and ChatPanel.NAMES.size() == 6,
			"%d / %d" % [ChatPanel.COLORS.size(), ChatPanel.NAMES.size()])

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("CHAT PANEL PASS" if failed == 0 else "CHAT PANEL FAIL")
	quit(0 if failed == 0 else 1)
