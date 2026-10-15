extends Node
## M4-1 音频管理：BGM + 办公室环境音
##
## 做成 **autoload 单例**而不是挂在场景里，是有原因的：
## 切场景（复盘会面板、结算面板、以后读档界面）时 AudioStreamPlayer 会被
## 跟着场景树一起释放，音乐会当场断掉。挂在 `/root` 下才跨场景存活。
##
## 音量取值的依据（不是"听着差不多"）：
##   BGM      -18 dB  —— 设计稿要求"不吵、能长时间听"
##   环境音   -24 dB  —— 底噪，永远在 BGM 下面 6dB
##   两者都写死在天花板以下，代码里不再出现 second_gain 之类的调节项：
##   玩家听 3 小时的东西，不能让任何一处音量是"运行时可调"的。
##
## 键盘音（M4-2）挂在这里，但播放走 `_keys` 池 + 距离衰减，
## 衰减和跟 LLM 流同步的逻辑在 key_audio.gd。

const SFX_DIR := "res://assets/sfx/"
const BGM_FILE := "bgm_office.ogg"
const AMB_FILE := "amb_office.ogg"
const KEY_FILES := ["key_1.ogg", "key_2.ogg", "key_3.ogg"]

const BGM_DB := -18.0
const AMB_DB := -24.0
# 距离衰减：最近 d_near 格听全响，最远 d_far 格外基本听不见
const KEY_NEAR := 4.0
const KEY_FAR := 18.0
const KEY_POOL := 10          # 同时最多几个键盘音（M4-2 要按这个算不重叠）

var bgm: AudioStreamPlayer
var amb: AudioStreamPlayer
var _keys: Array[AudioStreamPlayer] = []
var _key_streams: Array[AudioStream] = []
var _key_i := 0
var _rng := RandomNumberGenerator.new()

# 运行时状态：开关（面板按钮 / 测试用），不动音量档位
var bgm_on := true
var amb_on := true
var _ready_done := false


func _ready() -> void:
	# 确定性随机：同一个种子，同一局键盘音序列（M4-3 读档要复现）
	_rng.seed = 20261005
	bgm = _make_player(BGM_FILE, BGM_DB, true)
	amb = _make_player(AMB_FILE, AMB_DB, true)
	add_child(bgm)
	add_child(amb)
	for i in KEY_POOL:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_keys.append(p)
	for f in KEY_FILES:
		var path := SFX_DIR + String(f)
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if s != null:
				_key_streams.append(s)
	_ready_done = true
	print("[AUDIO] BGM=%s 环境音=%s 键盘音变体=%d 池=%d  %.0f/%.0f dB"
		% [BGM_FILE, AMB_FILE, _key_streams.size(), KEY_POOL, BGM_DB, AMB_DB])


func _make_player(file: String, db: float, loop: bool) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Master"
	p.volume_db = db
	var path := SFX_DIR + file
	if not ResourceLoader.exists(path):
		push_error("[AUDIO] 缺素材：%s" % path)
		return p
	var s: AudioStream = load(path)
	if s == null:
		push_error("[AUDIO] 素材加载失败：%s" % path)
		return p
	# ★循环必须显式打开。Ogg 文件本身不记"要不要循环"，忘了设就只播一遍然后静。
	#
	#   Godot 4.4 的 AudioStreamOggVorbis **只有** loop(bool) 和 loop_offset(float)，
	#   没有 loop_mode / LOOP_FORWARD / loop_end —— 那是 AudioStreamInteractive 的接口。
	#   我一开始照着 AudioStreamInteractive 写了个 set_loop_mode，解析期直接报
	#   "Cannot find member LOOP_FORWARD"，而且它**顺带把 autoload 也搞挂了**
	#   （"does not inherit from Node" 是脚本编译失败的连带报错，不是另一个问题）。
	#   查法：ClassDB.class_get_property_list("AudioStreamOggVorbis") 一次问清楚。
	if s is AudioStreamOggVorbis:
		var o: AudioStreamOggVorbis = s
		o.loop = loop
		o.loop_offset = 0.0
	else:
		s.loop = loop
	p.stream = s
	return p


## 显式释放（游戏退出路径调）。
##
## ★这里**不能**用 _exit_tree() 做清理：我第一版就挂在 _exit_tree 上，
##   结果"从树上摘下来"和"游戏退出"被当成同一件事——
##   而验证"切场景不中断"恰恰要把节点摘下来再挂回去，于是 7b/8b 两条当场红掉，
##   播放器已经被 stop + 清空了。摘下来 ≠ 退出，两者必须分开。
func dispose() -> void:
	stop_all()
	for p in _keys:
		p.stream = null
		p.free()
	_keys.clear()
	_key_streams.clear()
	if bgm != null:
		bgm.stream = null
		bgm.free()
		bgm = null
	if amb != null:
		amb.stream = null
		amb.free()
		amb = null


func start() -> void:
	if not _ready_done:
		return
	if bgm_on and not bgm.playing:
		bgm.play()
	if amb_on and not amb.playing:
		amb.play()
	print("[AUDIO] 播放中 bgm=%s amb=%s" % [bgm.playing, amb.playing])


func stop_all() -> void:
	bgm.stop()
	amb.stop()
	for p in _keys:
		p.stop()


## BGM 开关（面板按钮）。只切开关，不碰 volume_db。
func toggle_bgm() -> bool:
	bgm_on = not bgm_on
	if bgm_on:
		bgm.play()
	else:
		bgm.stop()
	return bgm_on


func toggle_amb() -> bool:
	amb_on = not amb_on
	if amb_on:
		amb.play()
	else:
		amb.stop()
	return amb_on


## 播一次键盘音，按距离衰减。M4-2 的核心入口。
##
## dist 是**格子数**（和游戏内坐标同一单位），不是像素。
## 衰减用线性 dB，衰减曲线用平方根距离：线性听感上 4 格和 9 格差不多近，
## 直接用线性距离会让远的人完全消失。
func play_key(dist: float, variant := -1) -> float:
	if _key_streams.is_empty():
		return -80.0
	var d := maxf(0.0, dist)
	var lin: float = clampf(1.0 - (d - KEY_NEAR) / (KEY_FAR - KEY_NEAR), 0.0, 1.0)
	var atten := sqrt(lin)                       # 距离 → 线性响度的感知曲线
	var db := -6.0 * (1.0 - atten) * 2.0          # 0~6 格不衰减，再远每格 6dB 到 -12dB 封底
	if lin <= 0.0:
		db = -40.0
	var p := _keys[_key_i]
	_key_i = (_key_i + 1) % _key_streams.size()
	var v := _key_i % _key_streams.size() if variant < 0 else variant % _key_streams.size()
	p.stream = _key_streams[v]
	p.volume_db = db
	p.play()
	return db


## 测试用：素材与配置的快照，不依赖场景树也能验。
##
## ★全程对 nil 做防御：probe() 崩掉的话，测试报告里只会多一行 SCRIPT ERROR，
##   真正没过的那些断言就全被盖掉了。崩和"断言失败"必须能分开看，
##   所以这里宁可返回 null 让用例去判 false，也不要抛异常。
func probe() -> Dictionary:
	var bgm_stream: AudioStream = bgm.stream if bgm != null else null
	var amb_stream: AudioStream = amb.stream if amb != null else null
	var ogg_loop := false
	if bgm_stream is AudioStreamOggVorbis:
		ogg_loop = (bgm_stream as AudioStreamOggVorbis).loop
	return {
		"ready": _ready_done,
		"bgm_file_exists": ResourceLoader.exists(SFX_DIR + BGM_FILE),
		"amb_file_exists": ResourceLoader.exists(SFX_DIR + AMB_FILE),
		"key_count": _key_streams.size(),
		"key_pool": KEY_POOL,
		"bgm_db": bgm.volume_db if bgm != null else 0.0,
		"amb_db": amb.volume_db if amb != null else 0.0,
		"bgm_loop": bgm_stream != null and bgm_stream.loop,
		"bgm_ogg_loop": ogg_loop,
		"bgm_playing": bgm.playing if bgm != null else false,
		"amb_playing": amb.playing if amb != null else false,
		"amb_loop": amb_stream != null and amb_stream.loop,
		"bgm_len": (bgm_stream.get_length() if bgm_stream else 0.0),
		"amb_len": (amb_stream.get_length() if amb_stream else 0.0),
		"key_near": KEY_NEAR,
		"key_far": KEY_FAR,
	}


## 距离衰减曲线取样，供 t_audio.gd 逐点验（不是只验"有输出"）
func key_atten_at(dist: float) -> float:
	var d := maxf(0.0, dist)
	var lin: float = clampf(1.0 - (d - KEY_NEAR) / (KEY_FAR - KEY_NEAR), 0.0, 1.0)
	return sqrt(lin)
