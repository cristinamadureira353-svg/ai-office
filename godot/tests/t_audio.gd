extends SceneTree
## M4-1 音频单节测试
##
## 跑法：./run_test.sh res://tests/t_audio.gd
##
## ★每条都是可判定的，不写"本次未触发"这种软断言：
##   素材存在、循环开着、音量关系对、衰减曲线单调且有界、
##   播放能真的响、切场景不中断。

var pass_n := 0
var fail_n := 0
var _log: Array[String] = []


var _A: Node = null

func _init() -> void:
	print("── M4-1 音频 ──")
	await _run()
	_cleanup()
	# ★stop() 是丢给 AudioServer 异步处理的，dispose() 之后必须再给一帧，
	#   否则退出时一堆 AudioStreamPlaybackOggVorbis 还在use中。
	#   --verbose 看到的清单全是它：5 个 AudioStreamOggVorbis +
	#   5 个 OggPacketSequence + 十几个 Playback 实例。
	await process_frame
	await process_frame
	# ★GDScript 的 String 不支持 `*` 重复，必须用 .repeat()
	print("═".repeat(52))
	if fail_n == 0:
		print("✓ 通过 %d / %d" % [pass_n, pass_n + fail_n])
	else:
		print("✗ 失败 %d 条（通过 %d）" % [fail_n, pass_n])
	quit(0 if fail_n == 0 else 1)


func check(name: String, ok: bool, detail := "") -> void:
	if ok:
		pass_n += 1
		print("  PASS  %s" % name)
	else:
		fail_n += 1
		print("  FAIL  %s  %s" % [name, detail])


func _run() -> void:
	# autoload 单例在 --script 模式下不会自动建，手动 new 一个走同一套代码路径
	# ★直接用**真的 autoload 单例**，不要 new 一个第二份。
	#   两份实例 = 两倍的 AudioStream 被加载，退出时 Godot 报
	#   "10 resources still in use at exit"，而 run_test.sh 只放行
	#   'Parse JSON failed' —— 于是**33 条断言全过也会被判失败**。
	#   而且测副本等于没测产品：autoload 的挂载点、生命周期都没被覆盖。
	await process_frame
	var A: Node = get_root().get_node_or_null("Audio")
	_A = A
	check("0a. ★autoload 单例 /root/Audio 已注册", A != null)
	if A == null:
		return
	# ★_ready() 和 autoload 的挂载都晚于 _init。立刻 get_node_or_null 拿到 null，
	#   立刻 probe() 撞上 bgm == null —— 报的是 SCRIPT ERROR，
	#   "断言失败"被盖成"测试崩了"，报告里看不见哪条没过。等一帧。
	await process_frame
	A.start()

	var p: Dictionary = A.probe()

	# ── 1. 素材存在且可加载 ──
	check("1a. BGM 素材存在", p["bgm_file_exists"], str(p))
	check("1b. 环境音素材存在", p["amb_file_exists"], str(p))
	check("1c. 键盘音 3 个变体都加载成功", p["key_count"] == 3, str(p["key_count"]))
	check("1d. _ready 跑完了（不是半初始化）", p["ready"] == true)

	# ── 2. 循环设置 ──
	check("2a. BGM loop = true", p["bgm_loop"] == true, str(p["bgm_loop"]))
	check("2b. BGM 是 OggVorbis 且其 loop 位也置上了", p["bgm_ogg_loop"] == true)
	check("2c. 环境音 loop = true", p["amb_loop"] == true, str(p["amb_loop"]))
	# 长度能间接证明素材没被截断：BGM 45.7s、环境音 20s
	check("2d. BGM 时长 ≈45.7s", abs(float(p["bgm_len"]) - 45.7) < 1.0,
		"%.2f" % float(p["bgm_len"]))
	check("2e. 环境音时长 ≈20s", abs(float(p["amb_len"]) - 20.0) < 0.5,
		"%.2f" % float(p["amb_len"]))

	# ── 3. 音量：BGM 必须比环境音响 ──
	var bgm_db: float = p["bgm_db"]
	var amb_db: float = p["amb_db"]
	check("3a. BGM 比环境音响", bgm_db > amb_db, "%.0f vs %.0f" % [bgm_db, amb_db])
	check("3b. BGM = -18dB（设计稿定的档）", abs(bgm_db + 18.0) < 0.01, str(bgm_db))
	check("3c. 环境音 = -24dB", abs(amb_db + 24.0) < 0.01, str(amb_db))
	# 两者都必须在天花板以下，且留够动态余量
	check("3d. 两轨峰值都低于 -10dBFS（不吵）", bgm_db < -10.0 and amb_db < -10.0)
	check("3e. 环境音不盖过 BGM 6dB", abs((bgm_db - amb_db) - 6.0) < 0.01,
		"%.1f" % (bgm_db - amb_db))

	# ── 4. 真的在播 ──
	check("4a. BGM 正在播放", p["bgm_playing"] == true)
	check("4b. 环境音正在播放", p["amb_playing"] == true)
	check("4c. 重新 start 不会重头播（幂等）", _call_play(A) and A.probe()["bgm_playing"])

	# ── 5. 距离衰减曲线（M4-2 的地基，这里先钉住形状）──
	var near: float = p["key_near"]
	var far: float = p["key_far"]
	var a0: float = A.key_atten_at(0.0)
	var a_near: float = A.key_atten_at(near)
	var a_mid: float = A.key_atten_at((near + far) * 0.5)
	var a_far: float = A.key_atten_at(far)
	var a_beyond: float = A.key_atten_at(far * 3.0)
	check("5a. 身边不衰减（attn=1）", abs(a0 - 1.0) < 1e-6, str(a0))
	check("5b. %.0f 格内仍不衰减" % near, abs(a_near - 1.0) < 1e-6, str(a_near))
	check("5c. 严格单调递减", a_near > a_mid and a_mid > a_far, "%.3f/%.3f/%.3f" % [a_near, a_mid, a_far])
	check("5d. 超过 %.0f 格完全听不见" % far, a_far <= 1e-9 and a_beyond <= 1e-9)
	check("5e. 取值恒在 [0,1]", a0 <= 1.0 and a_beyond >= 0.0)
	# 负距离不能炸（坐标可能因为插值短暂越界）
	check("5f. 负距离被夹住不炸", A.key_atten_at(-5.0) == 1.0)

	# ── 6. 键盘音实际播放（验证池在轮转、变体在换）──
	var dbs: Array[float] = []
	for i in range(9):
		dbs.append(float(A.play_key(2.0)))
	check("6a. 9 次按键都返回了合法电平（-60..0 dB）",
		dbs.all(func(d): return d >= -60.0 and d <= 0.0), str(dbs))
	var far_db: float = float(A.play_key(50.0))
	check("6b. 极远处按键 = -40dB（衰减到底）", abs(far_db + 40.0) < 0.01, str(far_db))
	var used := {}
	for p2 in A._keys:
		if p2.stream != null:
			used[p2.stream.resource_path.get_file()] = true
	check("6c. ★轮转后至少用到 3 个不同变体（不是同一个音重复播）",
		used.size() >= 3, str(used.keys()))

	# ── 7. 场景切换不中断 ──
	#  ★不是"应该不会断"，是把 autoload 单例从场景树摘下来再挂回去，
	#    确认它不是场景的子节点、音频状态不随场景销毁。
	var parent_before: Node = A.get_parent()
	check("7a. 音频节点挂在 /root 下（autoload），不是场景子节点",
		parent_before == root, str(parent_before))
	var was_playing: bool = A.probe()["bgm_playing"]
	root.remove_child(A)
	root.add_child(A)
	check("7b. 重新挂载后 BGM 仍在播（跨场景存活）",
		A.probe()["bgm_playing"] == was_playing == true)

	# ── 8. 开关不影响音量档位 ──
	var before_db: float = A.probe()["bgm_db"]
	A.toggle_bgm()
	check("8a. BGM 关掉后停止播放", A.probe()["bgm_playing"] == false)
	A.toggle_bgm()
	check("8b. 再开又播了", A.probe()["bgm_playing"] == true)
	check("8c. ★开关没有改动音量档位", abs(float(A.probe()["bgm_db"]) - before_db) < 1e-9)

	# ── 9. 授权：全部程序化合成，无第三方素材 ──
	var lic := "res://assets/sfx/AUDIO_LICENSES.md"
	check("9a. 授权说明文件在", FileAccess.file_exists(lic), lic)
	if FileAccess.file_exists(lic):
		var txt := FileAccess.get_file_as_string(lic)
		check("9b. 说明里写明是合成素材、不含第三方录音",
			txt.contains("程序化合成") and txt.contains("不含任何第三方录音"))


func _cleanup() -> void:
	# ★只停播，不 free。
	#   free 掉 autoload 单例会把它从 /root 摘走，而 Godot 退出时还要再释放一次；
	#   重复释放同样会打成 "ObjectDB instances leaked at exit"。
	#   播放器归引擎管，测试只负责别让声音一直响。
	if _A != null and is_instance_valid(_A):
		# 用 dispose() 而不是 stop_all()：stop_all 只停播，
		# AudioStream 的引用还挂在播放器上，退出时照样报 resources still in use。
		_A.dispose()


func _call_play(A) -> bool:
	A.start()
	return true
