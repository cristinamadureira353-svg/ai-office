extends SceneTree
## 桌面版对话面板的富文本渲染（M2-7 补充）
##
## 原生桌面版没有 HTML 层，Bot 的回复带表格、标题、代码和行内代码。
## 这里验证：Markdown 转成 BBCode 后，RichTextLabel 能排出真正的结构，
## 而不是把符号原样显示。

var passed := 0
var failed := 0
var panel: ChatPanel


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _init() -> void:
	await process_frame
	panel = ChatPanel.new()
	get_root().add_child(panel)
	await process_frame

	print("── 1 Markdown → BBCode 基础 ──")
	var bb := MarkdownBBCode.to_bbcode("**粗体** 和 `code`")
	check("1. 加粗变 [b]", bb.contains("[b]粗体[/b]"), bb)
	check("1b. 行内代码变 [code]", bb.contains("[code]code[/code]"), bb)
	check("1c. 不残留 markdown 星号", not bb.contains("**"), bb)

	var h := MarkdownBBCode.to_bbcode("## 小标题")
	check("2. 标题放大加粗", h.contains("[font_size=20]") and h.contains("[b]"), h)

	var it := MarkdownBBCode.to_bbcode("- 一
- 二")
	check("3. 列表变项目符号", it.contains("• 一") and it.contains("• 二"), it)

	var od := MarkdownBBCode.to_bbcode("1. 甲
2. 乙")
	check("4. 有序列表保留序号", od.contains("1. 甲") and od.contains("2. 乙"), od)

	var q := MarkdownBBCode.to_bbcode("> 引用一句")
	check("5. 引用变 quote", q.contains("[quote]引用一句[/quote]"), q)

	print("── 2 表格与代码块 ──")
	var t := MarkdownBBCode.to_bbcode("| 任务 | 状态 |\n|---|---|\n| 前端 | done |\n| 后端 | failed |")
	check("6. 表格变等宽块", t.contains("[codeblock]") and t.contains("│"), t)
	check("6b. 表格三行都在", t.count("│") >= 9, t)
	check("6c. 表格没留 markdown 竖线头", not t.contains("|---"), t)

	var cb := MarkdownBBCode.to_bbcode("```\nplain code\n```")
	check("7. 代码块变 codeblock", cb.contains("[codeblock]") and cb.contains("plain code"), cb)

	print("── 3 链接与转义 ──")
	var lk := MarkdownBBCode.to_bbcode("看 [文档](https://example.com)")
	check("8. 链接变 url", lk.contains("[url=https://example.com]文档[/url]"), lk)
	var bare := MarkdownBBCode.to_bbcode("地址 https://example.com/a_b_c 结束")
	check("8b. 裸链可点且下划线没被当斜体",
		bare.contains("[url=https://example.com/a_b_c]") and not bare.contains("[i]"), bare)
	var br := MarkdownBBCode.to_bbcode("数组 a[0] 和 b[1]")
	check("9. 正文方括号被转义，不会被当标签", br.contains("[lb]"), br)

	print("── 4 面板里真的排出了结构 ──")
	panel.open_with("m3")
	await process_frame
	panel.push_user("在干嘛呢")
	panel.begin_stream()
	panel.push_delta("## 复盘\n\n| 项 | 值 |\n|---|---|\n| 单 | 12 |\n\n- 第一条\n- 第二条")
	panel.end_stream()
	await process_frame

	var labels := panel._labels
	check("10. 每个气泡都有一个 RichTextLabel", labels.size() == 2, str(labels.size()))
	var bot_label: RichTextLabel = labels[1]
	check("10b. 气泡里是 BBCode 不是原文",
		bot_label.text.contains("[b]") or bot_label.text.contains("[codeblock]") or bot_label.text.contains("[font_size="),
		bot_label.text.substr(0, 120))
	check("10c. 原文里的 markdown 符号没进界面",
		not bot_label.text.contains("## ") and not bot_label.text.contains("|---"),
		bot_label.text.substr(0, 120))
	check("11. 富文本气泡比纯文本高（表格和列表撑开了）",
		bot_label.get_content_height() > 40.0, str(bot_label.get_content_height()))
	check("11b. 气泡高度也跟着变大", panel._layout[1]["height"] > 40.0, str(panel._layout[1]["height"]))
	check("12. 画布高度按气泡累加", panel._bubble_canvas.custom_minimum_size.y > 40.0,
		str(panel._bubble_canvas.custom_minimum_size.y))

	print("── 5 换人后不串台 ──")
	panel.open_with("kimi")
	await process_frame
	check("13. 换人后重建了气泡", panel._labels.size() == panel._layout.size(),
		"%d / %d" % [panel._labels.size(), panel._layout.size()])
	check("13b. 换人后没有残留上一个的气泡内容",
		panel._labels.is_empty() or not panel._labels[0].text.contains("复盘"),
		panel._labels[0].text.substr(0, 80) if not panel._labels.is_empty() else "")

	print("\n通过 %d / %d" % [passed, passed + failed])
	print("BBCODE PASS" if failed == 0 else "BBCODE FAIL")
	quit(0 if failed == 0 else 1)
