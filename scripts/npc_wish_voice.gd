class_name NpcWishVoice
extends Node
## 村民的「心愿漏话」播放器（见 docs/wish-leak-design.md）。
##
## 村民不经意漏一句自己想要什么 → 小朋友好奇了自己凑过去问 → 玩法是他挖出来的，不是被告知的。
## 台词由服务端按【这个玩家还没发现的玩法】下发（npc_wishes），本模块只管什么时候播、怎么播。
##
## 三条硬纪律：
##
## ① 漏话是环境音，必须【按距离衰减】——每个村民一个 AudioStreamPlayer3D 挂在自己身上。
##    全音量播出来就成了一屋子人在聊天房喊话，那不是「不经意听见」，是广播体操。
##    远处只是隐约一句嘟囔，走近了才听清——听不清本身就是勾好奇心的一部分。
##
## ② 绝不碰 world 的 _tts_player。那是对话通道，它的 playing 直接决定开麦门禁
##    （InteractionFsm.tts_busy）。漏话若占用它，小朋友想搭话的那一刻正好说不了话——
##    恰好毁掉整个机制。漏话播着也能随时被打断去对话，这是对的。
##
## ③ 必须【稀】。一个村民两分钟才嘟囔一句，路过时听见半句——这才叫不经意。
##    密了就是唠叨，比广告还烦。

const LEAK_COOLDOWN := 120.0  ## 每个村民两次漏话的最小间隔（秒）
const GLOBAL_GAP := 14.0      ## 任意两个村民之间的最小间隔——同一时刻全世界只有一个人在自言自语
const HEAR_RADIUS := 12.0     ## 触发半径：超出就不合成（省一次 TTS），进来了也还有 3D 衰减兜着
const UNIT_SIZE := 4.0        ## 3D 衰减：这个距离内基本满音量，之外按反平方衰减
const MAX_DISTANCE := 16.0    ## 超过这个距离完全听不见（比 HEAR_RADIUS 略大，走远了自然淡出）
const VOLUME_DB := -4.0       ## 漏话比对话轻一点——它是背景，不是主角

## characterId -> { voice_id: String, lines: PackedStringArray }
var _wishes: Dictionary = {}
var _next_ok: Dictionary = {}    ## characterId -> 可再次漏话的时刻
var _last_line: Dictionary = {}  ## characterId -> 上次说的那句（连着说同一句最出戏）
var _players: Dictionary = {}    ## characterId -> AudioStreamPlayer3D（挂在村民节点下）
var _global_next_ok := 0.0
var _t := 0.0
var _synthesizing := false       ## 合成在途：别并发起第二次

var edge_tts: EdgeTts            ## 由宿主注入（复用 world 那一个，共享探活与时钟纠偏）

func _process(delta: float) -> void:
	_t += delta

## 服务端下发的漏话候选（进世界/换场景/玩法被发现后都会重发）。
## 整份替换：心愿池变了（发现了新玩法、或花光了小红花），旧台词立即作废。
func set_wishes(list: Array) -> void:
	_wishes.clear()
	for w in list:
		var cid := String(w.get("characterId", ""))
		if cid.is_empty():
			continue
		var lines := PackedStringArray()
		for l in w.get("lines", []):
			lines.append(String(l))
		if lines.is_empty():
			continue
		_wishes[cid] = { "voice_id": String(w.get("voiceId", "")), "lines": lines }

func is_speaking() -> bool:
	for p in _players.values():
		var pl := p as AudioStreamPlayer3D
		if pl != null and is_instance_valid(pl) and pl.playing:
			return true
	return _synthesizing

## 每帧由宿主调用。npcs = world.npcs（[{id, node, logical, ...}]），player_pos = 玩家逻辑坐标。
## engaged = 玩家正在交互/录音/思考/听角色说话（此时全员闭嘴，别插话）。
func update(delta: float, npcs: Array, player_pos: Vector2, engaged: bool) -> void:
	_reap()
	if engaged or _synthesizing or _t < _global_next_ok or is_speaking():
		return
	# 候选：在听力半径内、不忙、没冷却、且服务端给了它台词的村民
	var pool: Array = []
	for n in npcs:
		if n.get("is_fairy", false):
			continue
		var cid := String(n.get("id", ""))
		if not _wishes.has(cid) or _t < float(_next_ok.get(cid, 0.0)):
			continue
		if _busy(n):
			continue
		var node := n.get("node") as Node3D
		if node == null or not is_instance_valid(node):
			continue
		if WorldGrid.shortest_delta(n.get("logical", Vector2.ZERO), player_pos).length() > HEAR_RADIUS:
			continue
		pool.append(n)
	if pool.is_empty():
		return
	_leak(pool[randi() % pool.size()])

## 这个村民此刻不该说话：正在跟人对话、正在演一个动作、或在被脚本驱动。
func _busy(n: Dictionary) -> bool:
	return bool(n.get("in_chat", false)) or not String(n.get("paper_action", "")).is_empty()

func _leak(n: Dictionary) -> void:
	var cid := String(n["id"])
	var w: Dictionary = _wishes[cid]
	var lines: PackedStringArray = w["lines"]
	var text := _pick_line(cid, lines)
	if text.is_empty():
		return
	# 先占坑再合成：合成要几百毫秒，期间别让第二个村民也开口
	_next_ok[cid] = _t + LEAK_COOLDOWN
	_global_next_ok = _t + GLOBAL_GAP
	_last_line[cid] = text
	_speak(n, cid, text, String(w["voice_id"]))

## 随机挑一句，但避开上次说的那句（只有一句可选时才重复）。
func _pick_line(cid: String, lines: PackedStringArray) -> String:
	if lines.is_empty():
		return ""
	var last := String(_last_line.get(cid, ""))
	if lines.size() == 1:
		return lines[0]
	for _i in range(8):
		var pick := lines[randi() % lines.size()]
		if pick != last:
			return pick
	return lines[0]

## 合成 → 挂在【这个村民身上】的 3D 音源播放（距离衰减在这里落地）。
## 服务端 TTS 降级不走这条路：漏话是可有可无的环境音，合成失败就算了，
## 不值得为它占用降级通道（那条路是留给对话的，对话丢了话小朋友会懵）。
func _speak(n: Dictionary, cid: String, text: String, voice_id: String) -> void:
	if edge_tts == null or not edge_tts.available or voice_id.is_empty():
		return
	_synthesizing = true
	var mp3: PackedByteArray = await edge_tts.synthesize(text, EdgeTts.map_voice(voice_id))
	_synthesizing = false
	if mp3.is_empty():
		return
	var node := n.get("node") as Node3D
	if node == null or not is_instance_valid(node):
		return # 合成期间这个村民没了（换场景/被删）：丢掉，别播到空气里
	var player := _player_for(cid, node)
	var stream := AudioStreamMP3.new()
	stream.data = mp3
	player.stream = stream
	player.play()

## 取（或懒建）挂在村民节点下的 3D 音源。挂在节点下 = 音源跟着他走，
## 距离衰减由引擎按玩家（listener）与音源的实际距离算——这正是老板要的「不是聊天房」。
func _player_for(cid: String, node: Node3D) -> AudioStreamPlayer3D:
	var p := _players.get(cid) as AudioStreamPlayer3D
	if p != null and is_instance_valid(p) and p.get_parent() == node:
		return p
	if p != null and is_instance_valid(p):
		p.queue_free() # 角色节点换了（重进场景）：旧音源跟着旧节点，弃了重建
	p = AudioStreamPlayer3D.new()
	p.unit_size = UNIT_SIZE
	p.max_distance = MAX_DISTANCE
	p.volume_db = VOLUME_DB
	node.add_child(p)
	_players[cid] = p
	return p

## 清掉已随角色节点销毁的音源引用（换场景/角色被删）。
func _reap() -> void:
	for cid in _players.keys():
		var p := _players[cid] as AudioStreamPlayer3D
		if p == null or not is_instance_valid(p):
			_players.erase(cid)
