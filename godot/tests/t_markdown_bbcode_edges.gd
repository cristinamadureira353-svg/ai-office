extends SceneTree
## markdown → BBCode 的边界用例（回归测试）
##
## 这些都是真机上会遇到的输入：Bot 是逐字吐出来的，
## 所以流式中间态一定包含没闭合的 ** 和 `。

var passed := 0
var failed := 0


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		passed += 1
		print("  PASS  ", name)
	else:
		failed += 1
		print("  FAIL  ", name, ("  → " + detail) if detail != "" else "")


func _init() -> void:
	await process_frame

	print("── 1 流式中间态：未闭合的强调标记不能被吃掉 ──")
	# Bot 正在吐 "**加粗" 时，只有两个星号。
	var half := MarkdownBBCode.to_bbcode("这是**粗")
	check("1. 未闭合的 ** 不会被当成一对斜号",
		not half.contains("[i]"), half)
	check("1b. 未闭合的 ** 也不会凭空造出加粗",
		not half.contains("[b]"), half)
	check("1c. 正文还在", half.contains("粗"), half)

	# 单个星号没闭合也不能配对
	var one := MarkdownBBCode.to_bbcode("评分 5 * 3 分")
	check("1d. 单独一个 * 不配对", not one.contains("[i]"), one)

	print("── 2 空格包围的星号不是斜体 ──")
	# "2 * 3 * 4" 是乘法，不是斜体。
	var math := MarkdownBBCode.to_bbcode("2 * 3 * 4 = 24")
	check("2. 乘法不被当斜体", not math.contains("[i]"), math)
	# 但 "*强调*" 仍然是斜体
	var em := MarkdownBBCode.to_bbcode("这是*强调*内容")
	check("2b. 紧贴文字的 * 仍然是斜体", em.contains("[i]强调[/i]"), em)

	print("── 3 表格里不能露出 markdown 符号 ──")
	var tbl := MarkdownBBCode.to_bbcode("| 项 | 值 |\n|---|---|\n| 行 | **303 行** |")
	check("3. 表格单元格里的 ** 被清掉", not tbl.contains("**"), tbl)
	check("3b. 文字本身还在", tbl.contains("303 行"), tbl)

	print("── 4 表格里含竖线的单元格不能错位 ──")
	var pipe := MarkdownBBCode.to_bbcode("| a | b |\n|---|---|\n| x | y\\|z |")
	# 断言的是「竖线留在同一个单元格里」这个事实本身。
	# 早先写成 not contains("│y  │z  │")，去掉转义后输出变成 "│y\ │z  │"，照样绿——
	# 那种写法抓不到它声称要守的 bug。
	check("4. 转义竖线留在同一个单元格里", pipe.contains("y|z"), pipe)

	print("── 5 正常用例不许被改坏 ──")
	var ok := MarkdownBBCode.to_bbcode("**粗** 和 *斜* 和 `码`")
	check("5. 加粗照旧", ok.contains("[b]粗[/b]"), ok)
	check("5b. 斜体照旧", ok.contains("[i]斜[/i]"), ok)
	check("5c. 行内代码照旧", ok.contains("[code]码[/code]"), ok)

	print("── 6 一行里同时有文字链接和裸链接 ──")
	# 两类链接各建一张表、各自从 0 编号的话，还原时索引会错位：
	# 裸链接会被文字链接顶替，地址整个消失，而且不报错。
	var mix := MarkdownBBCode.to_bbcode("看 [文档](https://a.example/doc) 和 https://b.example/x")
	check("6. 文字链接的地址还在", mix.contains("https://a.example/doc"), mix)
	check("6b. 裸链接的地址也还在", mix.contains("https://b.example/x"), mix)

	print("── 7 表格里的乘法不能丢星号 ──")
	# 表格走 codeblock，标记要清掉；但 "2 * 3 * 4" 里的星号是正文，不是标记。
	var tmul := MarkdownBBCode.to_bbcode("| 项 | 值 |\n|---|---|\n| 数量 | 2 * 3 * 4 |")
	check("7. 表格单元格里的乘号还在", tmul.contains("2 * 3 * 4"), tmul)

	print("── 8 内容带半角括号仍然加粗 ──")
	# 判「两侧贴空」只能认真空白，不能把半角右括号当空格。
	var paren := MarkdownBBCode.to_bbcode("**粗(x)**")
	check("8. 半角括号结尾仍然加粗", paren.contains("[b]粗(x)[/b]"), paren)

	quit(0 if failed == 0 else 1)
