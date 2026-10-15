extends Node2D
## M4-2 打字音效：随距离衰减，节奏跟 LLM 输出同步
##
## 挂在主场景下（**不是** autoload——打字音要跟着角色走，生命周期跟场景一致）。
## 五个角色各一个 AudioStreamPlayer2D，位置每帧跟着角色的世界坐标走。

const SFX := "res://assets/sfx/type_"

## 每个角色的基础按键间隔（毫秒）。这是"手速"的主要载体——
## 键击音的**音色**烤在素材里，**节奏**在这里，两边分开才调得动。
## ★间隔都要**高于** MIN_MS 留出余量。实测踩过：第一版 m3=120 / flash=62，
##   速度倍率又按 60 字/秒算，于是 cps=60 时 boost=2，所有人一起砸到 60ms 下限，
##   **五个人的手速在正常速率下完全分不出来**（kimi 72 / m3 60 / flash 60）。
##   现在基础值整体抬高、倍率归一化到 200 字/秒，低速区手速差异保留。
const BASE_MS := {
	"m3": 145.0,       # 慢而稳
	"flash": 78.0,     # 快而乱
	"longcat": 112.0,  # 中等
	"kimi": 168.0,     # 慢热（最慢）
	"step5": 86.0,     # 重而急
}
## 速率归一化：多少字/秒算"标准速度"（给 ×2）。真实 LLM 流式吐字 20~80 字/秒，
## 200 是给"很长的长文"留的档，不会让日常速率直接把所有人压到下限。
const RATE_NORM := 200.0
## 犹豫：按键后额外停顿的概率与倍数。Kimi 是"让我先想想"，敲两下停一下。
const HESITATE := {
	"kimi": [0.35, 2.6], "m3": [0.08, 1.8], "step5": [0.05, 1.5],
	"longcat": [0.10, 1.6], "flash": [0.04, 1.4],
}

## ★最小间隔 60ms：每秒最多 16.7 次，低于计划要求的 25 次上限。
##   不设下限的话 Flash 那种高速率会叠成一片噪音（音爆）。
const MIN_MS := 60.0
const MAX_MS := 400.0
## 距离衰减：线性增益，g = clamp(1 - d/MAX_D, 0, 1)
## 计划里写的是 max_distance=400 像素。地图 1280×768，
## 400 意味着只有屏幕中央那一块听得见——对"办公室里的打字声"是对的：
## 你听不见隔壁工位在敲什么，走近了才听得清。
const MAX_D := 400.0
const FLOOR_DB := -60.0
## 每个角色音量的个性化微调（音色已经有了，这里只做"谁更吵"）
const GAIN_DB := {"m3": -6.0, "flash": -9.0, "longcat": -6.0,
	"kimi": -8.0, "step5": -5.0}

var enabled := true
var muted := false
var master_db := 0.0

var _players: Dictionary = {}      # who -> AudioStreamPlayer2D
var _pos: Dictionary = {}          # who -> Vector2（世界坐标）
var _typing: Dictionary = {}       # who -> bool
var _cps: Dictionary = {}          # who -> float（字/秒）
var _next_at: Dictionary = {}      # who -> float（秒）
var _t_now := 0.0
var _rng := RandomNumberGenerator.new()
# 统计：给测试看，也给以后调平衡用
var _fired := 0
var _fired_by: Dictionary = {}


func _ready() -> void:
	# 固定种子：M4-3 读档要求同一局敲键盘的"犹豫"序列可复现
	_rng.seed = 20261005
	for who in BASE_MS:
		var p := AudioStreamPlayer2D.new()
		p.bus = "Master"
		# ★引擎的 attenuation 置 0：衰减曲线由下面的 atten_db() 自己算。
		#   引擎那套是黑盒公式，headless 下没法测，而我需要"中心比边缘大 N 倍"
		#   这种**能写进断言的数**。两边都做会衰减两次。
		p.attenuation = 0.0
		p.max_distance = MAX_D
		p.volume_db = GAIN_DB.get(who, -6.0)
		# ★SFX 是 const String，但 `who` 从 Dictionary 键取出来是 Variant，
		#   拼接结果推不出类型——GDScript 的 := 遇到 Variant 就报解析期错。
		var path: String = String(SFX) + String(who) + ".ogg"
		if ResourceLoader.exists(path):
			p.stream = load(path)
		else:
			push_error("[TYPING] 缺素材 %s" % path)
		add_child(p)
		_players[who] = p
		_pos[who] = Vector2.ZERO
		_typing[who] = false
		_cps[who] = 0.0
		_next_at[who] = 0.0
		_fired_by[who] = 0
	print("[TYPING] 5 个打字音源就绪，衰减 %dpx 自算，间隔下限 %.0fms"
		% [int(MAX_D), MIN_MS])


func _process(delta: float) -> void:
	_t_now += delta
	if not enabled or muted:
		return
	for who in _players:
		var p: AudioStreamPlayer2D = _players[who]
		p.global_position = _pos.get(who, Vector2.ZERO)
		if p.global_position == Vector2.ZERO:
			continue                       # 位置还没同步，别在半路响
		if not _typing.get(who, false):
			# 收工即停：正在响的那一下让它自然衰减完，不硬切（会咔哒）
			continue
		if _t_now < float(_next_at.get(who, 0.0)):
			continue
		var listener := Vector2.ZERO
		if get_viewport().get_camera_2d() != null:
			listener = get_viewport().get_canvas_transform().affine_inverse() * (get_viewport_rect().size * .5)
		var db: float = atten_db(p.global_position.distance_to(listener))
		if db <= FLOOR_DB:
			_next_at[who] = _t_now + 0.05    # 听不见就别占触发预算
			continue
		p.volume_db = float(GAIN_DB.get(who, -6.0)) + db + master_db
		p.play()
		_fired += 1
		_fired_by[who] = int(_fired_by.get(who, 0)) + 1
		_next_at[who] = _t_now + interval_of(who) / 1000.0


## 喂一次后端快照：位置 + 是否在打字 + 输出速率
func sync(state: Dictionary) -> void:
	# ★先把所有"正在打字"清掉，再按本次快照设。
	#   原来只遍历快照里出现的 worker，于是**上一帧还在打字、这一帧没出现在
	#   快照里的人会一直打下去**——实测 5a（干完活立刻停止）就是这么红的：
	#   测试连着喂 5 个角色，前 4 个的 typing 标记从没被清过。
	#   真实快照永远含全部 5 人，所以生产上不易撞上；但"人以快照为准"这条
	#   规则本身就该在 sync 里写死，不能依赖调用方每次都喂全。
	var previous := _typing.duplicate()
	for who in _typing:
		_typing[who] = false
		_cps[who] = 0.0
	for w in state.get("workers", []):
		var who := String(w.get("id", ""))
		if not _players.has(who):
			continue
		_pos[who] = Vector2(float(w.get("x", 0.0)), float(w.get("y", 0.0)))
		var was: bool = bool(previous.get(who, false))
		_typing[who] = bool(w.get("typing", false))
		_cps[who] = float(w.get("type_cps", 0.0))
		# ★刚开始打字要**立刻响第一下**。不快进的话，模型已经吐了 200 字
		#   客户端才反应过来，听感上就是"先安静两秒然后突然哒哒哒"。
		if _typing[who] and not was:
			_next_at[who] = 0.0


## 本次按键间隔（毫秒）：基础手速 × 输出速率，夹在 [MIN_MS, MAX_MS]
##
## 关键：间隔跟着 **type_cps**（模型实际吐字速度）走，不是固定值。
## 模型在长思考、卡顿、输出稀疏时，间隔自动拉长——这就是"停顿处也停顿"。
func interval_of(who: String, cps := -1.0) -> float:
	var base: float = float(BASE_MS.get(who, 100.0))
	var rate: float = cps if cps >= 0.0 else float(_cps.get(who, 0.0))
	# 60 字/秒算"标准速度"；2 倍速 → 间隔除以 2
	var boost: float = clampf(1.0 + rate / RATE_NORM, 0.6, 2.4)
	var ms: float = base / boost
	# 犹豫：Kimi 会敲两下停一下
	var h: Array = HESITATE.get(who, [0.0, 1.0])
	if h.size() == 2 and _rng.randf() < float(h[0]):
		ms *= float(h[1])
	return clampf(ms, MIN_MS, MAX_MS)


## 距离 → 附加增益（dB）。线性增益，0dB → FLOOR_DB。
## 纯函数：不碰场景树，测试可以直接对任意距离取样验曲线。
static func atten_db(dist: float) -> float:
	var g: float = clampf(1.0 - maxf(0.0, dist) / MAX_D, 0.0, 1.0)
	if g <= 0.0001:
		return FLOOR_DB
	return maxf(FLOOR_DB, 20.0 * log(g) / log(10.0))


## 线性增益形式（测试更易读：直接比倍数）
static func atten_gain(dist: float) -> float:
	return clampf(1.0 - maxf(0.0, dist) / MAX_D, 0.0, 1.0)


## 测试用快照
func probe() -> Dictionary:
	return {
		"players": _players.size(),
		"streams": _fired_streams(),
		"fired": _fired,
		"fired_by": _fired_by.duplicate(),
		"max_d": MAX_D, "min_ms": MIN_MS, "max_ms": MAX_MS,
		"base_ms": BASE_MS.duplicate(),
		"enabled": enabled, "muted": muted,
		"typing": _typing.duplicate(),
		"cps": _cps.duplicate(),
	}


func _fired_streams() -> int:
	var n := 0
	for who in _players:
		var p: AudioStreamPlayer2D = _players[who]
		if p.stream != null:
			n += 1
	return n


## 测试用：手动跑 N 帧 _process，不依赖真实时间
func tick(n: int, step := 0.016) -> void:
	for i in n:
		_process(step)


func set_muted(v: bool) -> void:
	muted = v
	if v:
		for who in _players:
			(_players[who] as AudioStreamPlayer2D).stop()


func set_master_db(v: float) -> void:
	master_db = clampf(v, -40.0, 6.0)
