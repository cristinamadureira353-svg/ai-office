class_name MarkdownBBCode
extends RefCounted
## Markdown → BBCode（Godot RichTextLabel）
##
## 原生桌面版没有 HTML 层，Bot 的回复还是一段纯文本。这里把 Markdown
## 转成 RichTextLabel 认的 BBCode，标题/加粗/列表/行内代码/引用能正常排版，
## 表格用等宽块对齐（Godot 没有 table 标签）。
##
## 规则：
##   标题 # ~ ######  → 加粗放大
##   **粗**  *斜*  ~~删~~
##   `行内代码`
##   ``` 代码块 ```  → codeblock
##   > 引用          → quote
##   - / * / + 列表   → 项目符号
##   1. 有序列表      → 保留序号
##   | 表格 |        → 等宽对齐块
##   ---             → 分隔线
##   [文字](链接)     → url
##   裸链接           → url
##
## ★Bot 是逐字吐出来的，流式中间态一定出现没闭合的标记。
##   所以这里的规则比 CommonMark 更保守：没配对就不转，两侧贴空也不转。
##   早先的实现会把孤零零的 "**" 当成一对斜号，加粗的字先正常显示、
##   再突然变成普通字，闪一下。

## 占位符前缀：代码和链接各一类。
## 两种链接（[文字](链接) 和裸链接）**共用**同一个前缀和同一张表，
## 编号才全局唯一——各建一张表、各自从 0 编号，还原时索引会错位。
const PH_CODE := "\uE000"     # 行内代码
const PH_LINK := "\uE001"     # 链接（带文字的、裸的）

const HEAD_SIZE := 20
const BULLET := "• "
const TABLE_SEP := "│"


## 把 Markdown 原文转成 BBCode。
static func to_bbcode(md: String) -> String:
	var src: String = md if md != null else ""
	src = src.replace("\r\n", "\n").replace("\r", "\n")
	var lines := src.split("\n")
	var out: Array[String] = []
	var i := 0
	while i < lines.size():
		var line := lines[i]

		# 代码块
		if _is_fence(line):
			var lang := ""
			var parts := line.strip_edges().split(" ", false)
			if parts.size() > 1:
				lang = parts[1]
			var body: Array[String] = []
			i += 1
			while i < lines.size() and not _is_fence(lines[i]):
				body.append(lines[i])
				i += 1
			i += 1
			var head := "" if lang.is_empty() else lang + "\n"
			out.append("[codeblock]" + head + "\n".join(body) + "[/codeblock]")
			continue

		# 表格
		if _is_row(line) and i + 1 < lines.size() and _is_separator(lines[i + 1]):
			var block: Array[String] = []
			while i < lines.size() and _is_row(lines[i]):
				block.append(lines[i])
				i += 1
			out.append(_table(block))
			continue

		# 分隔线
		if _is_hr(line):
			out.append("[hr]")
			i += 1
			continue

		# 标题
		if line.begins_with("#"):
			var hashes := ""
			while hashes.length() < line.length() and line[hashes.length()] == "#":
				hashes += "#"
			var text := line.substr(hashes.length()).strip_edges()
			if not text.is_empty():
				out.append("[font_size=%d][b]%s[/b][/font_size]" % [HEAD_SIZE, _inline(text)])
			i += 1
			continue

		# 引用
		if line.begins_with(">"):
			var quote: Array[String] = []
			while i < lines.size() and lines[i].begins_with(">"):
				quote.append(lines[i].substr(1).strip_edges())
				i += 1
			out.append("[quote]" + "\n".join(quote.map(func(x): return _inline(x))) + "[/quote]")
			continue

		# 列表
		if _is_bullet(line) or _is_ordered(line):
			var items: Array[String] = []
			while i < lines.size() and (_is_bullet(lines[i]) or _is_ordered(lines[i])):
				items.append(_list_item(lines[i]))
				i += 1
			out.append("[indent]" + "\n".join(items) + "[/indent]")
			continue

		# 空行：段落分隔
		if line.strip_edges().is_empty():
			i += 1
			continue

		# 普通段落：连续非空行合成一段
		var para: Array[String] = []
		while i < lines.size() and not lines[i].strip_edges().is_empty() \
				and not _is_fence(lines[i]) and not _is_row(lines[i]) \
				and not lines[i].begins_with("#") and not lines[i].begins_with(">") \
				and not _is_bullet(lines[i]) and not _is_ordered(lines[i]) \
				and not _is_hr(lines[i]):
			para.append(lines[i])
			i += 1
		if not para.is_empty():
			out.append("\n".join(para.map(func(x): return _inline(x))))
	return "\n".join(out)


# ── 行内标记 ─────────────────────────────────────────────────────────────
static func _inline(text: String) -> String:
	# 顺序要紧：链接和代码先摘成占位符，再转义方括号，最后才处理强调标记。
	# 反过来的话，链接里的 [ 会被转义掉、代码里的 * 会被当强调。
	var codes: Array[String] = []
	var links: Array[String] = []
	# 先摘带文字的链接，再摘裸链接：反过来的话，[文档](https://x) 里的
	# 地址会被裸链接扫描器先吃掉，链接文字就丢了。
	# ★两者往同一张 links 表里追加：各建一张、各自从 0 编号的话，还原时
	#   索引会错位——一行里同时出现两种链接，裸链接会被文字链接顶替、
	#   地址整个消失，而且不报错。
	var s := _extract_links(text, links)
	s = _extract_bare_links(s, links)
	s = _escape(s)
	s = _extract_code(s, codes)
	s = _apply_strike(s)
	s = _emphasis(s, true)
	for i in codes.size():
		s = s.replace(PH_CODE + str(i) + PH_CODE, "[code]" + codes[i] + "[/code]")
	for i in links.size():
		s = s.replace(PH_LINK + str(i) + PH_LINK, links[i])
	return s


## 把 `x` 换成占位符，避免里面的符号被当强调。
static func _extract_code(s: String, codes: Array[String]) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "`":
			var close := s.find("`", i + 1)
			if close > i:
				codes.append(s.substr(i + 1, close - i - 1))
				out += PH_CODE + str(codes.size() - 1) + PH_CODE
				i = close + 1
				continue
		out += s[i]
		i += 1
	return out


## 处理成对的强调标记（** 加粗、* 斜体）。
##
## emit_tags=true 出 BBCode；false 只留内容、把标记丢掉。
## 表格走 codeblock，里面 BBCode 不生效，标记必须清掉——但正文里的乘号
## 不是标记。两种用途共用这一套配对规则：早先表格那边自己写了一套，
## 结果 "| 2 * 3 * 4 |" 的乘号被吃掉，变成 "2  3  4"。
##
## ★两条规则都是从真机踩出来的：
##   1. 没配对就不转。Bot 是逐字吐出来的，流式中间态一定出现孤零零的
##      "**"——早先的实现把它当成一对斜号，输出 "[i][/i]"，
##      加粗的文字会先正常显示、再突然变成普通字（闪一下）。
##   2. 两侧不能挨空白。"2 * 3 * 4" 是乘法不是斜体；
##      CommonMark 也是这条规则，两侧贴空的星号一律当普通字符。
static func _emphasis(s: String, emit_tags: bool) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] != "*":
			out += s[i]
			i += 1
			continue
		var width := 1
		while i + width < s.length() and s[i + width] == "*":
			width += 1
		if width > 2:
			# 三个以上的星号不是强调，原样留着。
			out += "*".repeat(width)
			i += width
			continue
		var close := -1
		var j := i + width
		while j < s.length():
			if s[j] == "*":
				var run := 1
				while j + run < s.length() and s[j + run] == "*":
					run += 1
				if run == width:
					close = j
					break
				j += run
				continue
			j += 1
		if close < 0:
			# 没有配对的另一半：流式中间态，原样输出。
			out += "*".repeat(width)
			i += width
			continue
		var content := s.substr(i + width, close - i - width)
		# ★看的是**内容**的首尾，不是标记外侧：
		#   "**粗**" 的内容是"粗"，两边不挨空格 → 加粗；
		#   "2 * 3 * 4" 的内容是" 3 "，挨空格 → 是乘法，不是斜体。
		#   CommonMark 也是这条规则。
		if content.is_empty() or _is_ws(content[0]) or _is_ws(content[content.length() - 1]):
			out += "*".repeat(width)
			i += width
			continue
		if not emit_tags:
			out += content
		elif width == 2:
			out += "[b]" + content + "[/b]"
		else:
			out += "[i]" + content + "[/i]"
		i = close + width
	return out


## 处理成对的删除线（~~）。
static func _apply_strike(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s.substr(i, 2) == "~~":
			var close := s.find("~~", i + 2)
			if close > i:
				out += "[s]" + s.substr(i + 2, close - i - 2) + "[/s]"
				i = close + 2
				continue
		out += s[i]
		i += 1
	return out


## [文字](链接) → [url=链接]文字[/url]；链接先摘成占位符，免得
## 里面的 _ 被当斜体、方括号被转义。
## links 由调用方传进来，和裸链接共用一张表，编号才全局唯一。
static func _extract_links(s: String, links: Array[String]) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "[":
			var close := s.find("](", i)
			if close > i:
				var end := s.find(")", close + 2)
				if end > close:
					var label := s.substr(i + 1, close - i - 1)
					var url := s.substr(close + 2, end - close - 2)
					links.append("[url=" + url + "]" + label + "[/url]")
					out += PH_LINK + str(links.size() - 1) + PH_LINK
					i = end + 1
					continue
		out += s[i]
		i += 1
	return out


## 裸链接（http/https）也变成可点的。URL 里的下划线不能被当斜体，所以同样先摘出来。
static func _extract_bare_links(s: String, links: Array[String]) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s.substr(i, 7) == "http://" or s.substr(i, 8) == "https://":
			var end := i
			while end < s.length() and not _is_url_end(s[end]):
				end += 1
			var url := s.substr(i, end - i)
			links.append("[url=" + url + "]" + url + "[/url]")
			out += PH_LINK + str(links.size() - 1) + PH_LINK
			i = end
			continue
		out += s[i]
		i += 1
	return out


## 只认真正的空白字符。
## 加粗判「两侧贴空白」必须用这个：早先那张表里混进了半角右括号，
## 结果 "**粗(x)**" 被判成两侧贴空、加粗直接失效。
static func _is_ws(c: String) -> bool:
	return c == " " or c == "\t" or c == "\n" or c == "\r"


## 裸链接到哪里结束：空白和常见的收尾标点都算。
## 不能和 _is_ws 共用——那是两个问题：加粗只认空白，
## 链接则必须在 "，" "。" ")" 这些标点前断开。
static func _is_url_end(c: String) -> bool:
	return _is_ws(c) or c == ")" or c == "（" or c == "）" \
			or c == "，" or c == "。" or c == "、" or c == "！" or c == "？" \
			or c == "；" or c == "：" or c == "]" or c == ">" or c == "\""


## BBCode 里 [ 是标签开头，正文里的方括号要转义。
static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


# ── 表格 ────────────────────────────────────────────────────────────────
static func _table(block: Array[String]) -> String:
	var rows: Array = []
	for idx in block.size():
		if idx == 1:
			continue
		rows.append(_cells(block[idx]))
	if rows.is_empty():
		return ""
	# 列宽按内容最大宽度算，中文算两格
	var cols := 0
	for row in rows:
		cols = maxi(cols, row.size())
	var widths: Array[int] = []
	for c in cols:
		var w := 3
		for row in rows:
			if c < row.size():
				w = maxi(w, _display_width(str(row[c])))
		widths.append(w)
	var lines: Array[String] = []
	for row in rows:
		var cells: Array[String] = []
		for c in cols:
			var cell := "" if c >= row.size() else str(row[c])
			cells.append(cell + " ".repeat(maxi(0, widths[c] - _display_width(cell))))
		lines.append(TABLE_SEP + TABLE_SEP.join(cells) + TABLE_SEP)
	return "[codeblock]" + "\n".join(lines) + "[/codeblock]"


static func _cells(line: String) -> Array:
	var s := line.strip_edges()
	# 转义竖线（\|）先摘成占位符，免得被当成列分隔。
	s = s.replace("\\|", "\uE003")
	if s.begins_with("|"):
		s = s.substr(1)
	if s.ends_with("|"):
		s = s.substr(0, s.length() - 1)
	var out: Array = []
	for cell in s.split("|"):
		out.append(_strip_marks(cell.replace("\uE003", "|")).strip_edges())
	return out


## 表格走的是 codeblock（等宽），BBCode 在里面不生效，
## 所以单元格里残留的 markdown 标记要自己去掉，
## 否则玩家会看到一整排裸的 ** 和 `。
static func _strip_marks(text: String) -> String:
	# 星号交给 _emphasis(…, false)：它认得出哪个星号是标记、哪个是乘号。
	# 这里自己再写一套配对的话，两套规则迟早打架。
	return _emphasis(text.replace("~~", "").replace("`", ""), false)


## 显示宽度：中文与全角算两格。
static func _display_width(text: String) -> int:
	var w := 0
	for i in text.length():
		var code := text.unicode_at(i)
		if (code >= 0x1100 and code <= 0x115F) or (code >= 0x2E80 and code <= 0xA4CF) \
				or (code >= 0xAC00 and code <= 0xD7A3) or (code >= 0xF900 and code <= 0xFAFF) \
				or (code >= 0xFE30 and code <= 0xFE6F) or (code >= 0xFF00 and code <= 0xFF60) \
				or (code >= 0xFFE0 and code <= 0xFFE6):
			w += 2
		else:
			w += 1
	return w


# ── 行判定 ──────────────────────────────────────────────────────────────
static func _is_fence(line: String) -> bool:
	return line.strip_edges().begins_with("```")


static func _is_row(line: String) -> bool:
	var s := line.strip_edges()
	return s.begins_with("|") and s.ends_with("|") and s.length() > 2


static func _is_separator(line: String) -> bool:
	var s := line.strip_edges()
	if not s.begins_with("|"):
		return false
	for c in s:
		if c != "|" and c != "-" and c != ":" and c != " ":
			return false
	return s.count("-") >= 2


static func _is_hr(line: String) -> bool:
	var s := line.strip_edges()
	if s.length() < 3:
		return false
	for c in s:
		if c != "-" and c != "*" and c != "_" and c != " ":
			return false
	return s.count("-") >= 3 or s.count("*") >= 3 or s.count("_") >= 3


static func _is_bullet(line: String) -> bool:
	var s := line.strip_edges()
	return s.begins_with("- ") or s.begins_with("* ") or s.begins_with("+ ")


## 行首的数字串（有序列表的序号）。
static func _leading_digits(s: String) -> String:
	var digits := ""
	for i in s.length():
		if s[i] >= "0" and s[i] <= "9":
			digits += s[i]
		else:
			break
	return digits


static func _is_ordered(line: String) -> bool:
	var s := line.strip_edges()
	var digits := _leading_digits(s)
	return digits != "" and s.substr(digits.length(), 2) == ". "


static func _list_item(line: String) -> String:
	var s := line.strip_edges()
	var digits := _leading_digits(s)
	if digits != "" and s.substr(digits.length(), 2) == ". ":
		return digits + ". " + _inline(s.substr(digits.length() + 2))
	return BULLET + _inline(s.substr(2))
