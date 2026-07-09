class_name EdgeTts
extends Node
## 微软 edge-tts 云端合成客户端（协议移植自 Python edge-tts 7.x，见 docs/edge-tts-client-design.md）。
## 平板直连 wss://speech.platform.bing.com 合成 mp3；服务端 TTS 只作降级路径。
## 用法：await probe() 探活+时钟纠偏 → var mp3 := await synthesize(text, edge_voice)；失败返回空 PackedByteArray。
## 非官方接口：Sec-MS-GEC 校验历史上多次变更导致社区库失效——调用方必须处理失败降级（world.gd 走 tts_request）。

const TRUSTED_TOKEN := "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
const BASE_URL := "speech.platform.bing.com/consumer/speech/synthesize/readaloud"
const CHROMIUM_FULL := "143.0.3650.75"
const SEC_MS_GEC_VERSION := "1-" + CHROMIUM_FULL
const WIN_EPOCH := 11644473600
## 合成超时：实测整句中位 300ms、冷启动 <1s；4s 没拿到 turn.end 视为失败走降级。
const SYNTH_TIMEOUT_SEC := 4.0

## 探活成功（拿到音色表 + Date 纠偏）后置位；合成失败会复位，由调用方安排重探。
var available := false
## 微软服务器时钟 - 本机时钟（秒）。Sec-MS-GEC 按 5 分钟窗口取整，平板时钟漂移必须纠正。
var clock_skew := 0.0

var _ws: WebSocketPeer = null
var _mp3 := PackedByteArray()
var _synth_deadline := 0.0
var _config_sent := false
var _busy := false

signal _synth_done(ok: bool)

## ── 纯函数（单测覆盖）─────────────────────────────────────────────

## 服务端 voiceId → edge 音色。取值域：仙子 mock-voice-cn-fairy、LLM 造的角色 cn-child-default、
## 手配的 MiniMax 名（lovely_girl 等）、Kokoro zf_*/zm_*；未知按稳定哈希落池（同一 id 永远同声）。
const _VOICE_MAP := {
	"mock-voice-cn-fairy": "zh-CN-XiaoyiNeural", # 仙子：活泼女声（老板试听样本）
	"cn-child-default": "zh-CN-YunxiaNeural", # 默认角色：小孩音
	"lovely_girl": "zh-CN-XiaoyiNeural",
	"cute_boy": "zh-CN-YunxiaNeural",
	"clever_boy": "zh-CN-YunxiNeural",
	"cartoon_pig": "zh-CN-YunxiaNeural",
	"female-tianmei": "zh-CN-XiaoxiaoNeural",
}
const _VOICE_POOL := ["zh-CN-XiaoyiNeural", "zh-CN-YunxiaNeural", "zh-CN-XiaoxiaoNeural", "zh-CN-YunxiNeural"]

static func map_voice(voice_id: String) -> String:
	# 服务端音色目录（voice_catalog.ts）直接下发 edge 原生音色名：直通不映射
	if voice_id.begins_with("zh-"):
		return voice_id
	if _VOICE_MAP.has(voice_id):
		return _VOICE_MAP[voice_id]
	if voice_id.begins_with("zf_"):
		return "zh-CN-XiaoxiaoNeural"
	if voice_id.begins_with("zm_"):
		return "zh-CN-YunxiNeural"
	return _VOICE_POOL[voice_id.hash() % _VOICE_POOL.size()]

## Sec-MS-GEC：Windows 文件时间（unix+纪元差）向下取整到 5 分钟 → 100ns tick → 拼 token 走 SHA256 大写。
## 整数运算与 Python 参考实现逐位一致（乘积有效位 <2^53，float 路径也精确，见 test_edge_tts 参考值）。
static func gen_sec_ms_gec(unix_time: float) -> String:
	var t := int(floor(unix_time)) + WIN_EPOCH
	t -= t % 300
	var ticks := t * 10000000
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update((str(ticks) + TRUSTED_TOKEN).to_utf8_buffer())
	return ctx.finish().hex_encode().to_upper()

## SSML 正文（音色 + 默认韵律；文本须已 xml_escape）。
static func build_ssml(escaped_text: String, voice: String) -> String:
	return ("<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
		+ "<voice name='%s'><prosody pitch='+0Hz' rate='+0%%' volume='+0%%'>%s</prosody></voice></speak>") % [voice, escaped_text]

## 二进制帧 → mp3 载荷：前 2 字节大端 header 长度，头块须含 Path:audio；否则返回空。
static func parse_audio_frame(frame: PackedByteArray) -> PackedByteArray:
	if frame.size() < 2:
		return PackedByteArray()
	var header_len := frame[0] << 8 | frame[1]
	if 2 + header_len > frame.size():
		return PackedByteArray()
	var header := frame.slice(2, 2 + header_len).get_string_from_utf8()
	if not header.contains("Path:audio"):
		return PackedByteArray()
	return frame.slice(2 + header_len)

## HTTP Date 头（RFC 2616，如 "Thu, 09 Jul 2026 08:14:00 GMT"）→ unix 秒；解析失败返回 -1。
static func parse_http_date(date: String) -> int:
	const MONTHS := { "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
		"Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12 }
	var parts := date.strip_edges().split(" ", false)
	if parts.size() < 6 or not MONTHS.has(parts[2]):
		return -1
	var hms := parts[4].split(":")
	if hms.size() != 3:
		return -1
	return int(Time.get_unix_time_from_datetime_dict({
		"year": int(parts[3]), "month": MONTHS[parts[2]], "day": int(parts[1]),
		"hour": int(hms[0]), "minute": int(hms[1]), "second": int(hms[2]),
	}))

## 32 位随机 hex（ConnectionId / muid 用）。
static func rand_hex32() -> String:
	var bytes := PackedByteArray()
	bytes.resize(16)
	for i in 16:
		bytes[i] = randi() % 256
	return bytes.hex_encode()

## ── 探活 + 时钟纠偏 ───────────────────────────────────────────────

## 拉音色表探活：通 = available；同时用响应 Date 头纠正本机时钟偏移（与 Python 库 403 才纠偏不同，
## 这里每次探活都纠——多做一次减法换掉一整类 5 分钟窗口边界失败）。
func probe() -> bool:
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	var url := "https://" + BASE_URL + "/voices/list?trustedclienttoken=" + TRUSTED_TOKEN
	var err := http.request(url, _base_headers())
	if err != OK:
		http.queue_free()
		available = false
		return false
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		available = false
		return false
	for h in res[2] as PackedStringArray:
		var line := String(h)
		if line.to_lower().begins_with("date:"):
			var server_ts := parse_http_date(line.substr(5))
			if server_ts > 0:
				clock_skew = float(server_ts) - Time.get_unix_time_from_system()
	available = true
	return true

## ── 合成 ─────────────────────────────────────────────────────────

## 文本+edge 音色 → 完整 mp3（audio-24khz-48kbitrate-mono-mp3）。失败返回空 PackedByteArray 并复位 available。
## 单飞：上一句未完成时直接失败（调用方本就串行播放，不排队）。
func synthesize(text: String, voice: String) -> PackedByteArray:
	if _busy or text.strip_edges().is_empty():
		return PackedByteArray()
	_busy = true
	_ws = WebSocketPeer.new()
	_ws.handshake_headers = PackedStringArray([
		"User-Agent: " + _user_agent(),
		"Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold",
		"Pragma: no-cache",
		"Cache-Control: no-cache",
		"Cookie: muid=" + rand_hex32().to_upper() + ";",
	])
	var url := ("wss://" + BASE_URL + "/edge/v1?TrustedClientToken=" + TRUSTED_TOKEN
		+ "&ConnectionId=" + rand_hex32()
		+ "&Sec-MS-GEC=" + gen_sec_ms_gec(Time.get_unix_time_from_system() + clock_skew)
		+ "&Sec-MS-GEC-Version=" + SEC_MS_GEC_VERSION)
	_mp3 = PackedByteArray()
	_config_sent = false
	_synth_deadline = Time.get_ticks_msec() / 1000.0 + SYNTH_TIMEOUT_SEC
	# 请求体在连上后由 _process 发（speech.config + SSML），这里只发起握手
	_pending_ssml = build_ssml(text.xml_escape(), voice)
	if _ws.connect_to_url(url) != OK:
		# 还没人 await，不能走 _finish 的 emit（信号会发进空气，随后的 await 永久挂起）
		_ws = null
		_busy = false
		available = false
		return PackedByteArray()
	set_process(true)
	var ok: bool = await _synth_done
	return _mp3 if ok else PackedByteArray()

var _pending_ssml := ""

func _process(_delta: float) -> void:
	if _ws == null:
		set_process(false)
		return
	_ws.poll()
	var now := Time.get_ticks_msec() / 1000.0
	if now > _synth_deadline:
		_finish(false)
		return
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _config_sent:
				_config_sent = true
				_ws.send_text("X-Timestamp:%s\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n" % _js_date()
					+ '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n')
				_ws.send_text("X-RequestId:%s\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:%sZ\r\nPath:ssml\r\n\r\n%s" % [rand_hex32(), _js_date(), _pending_ssml])
			while _ws.get_available_packet_count() > 0:
				var pkt := _ws.get_packet()
				if _ws.was_string_packet():
					if pkt.get_string_from_utf8().contains("Path:turn.end"):
						_finish(not _mp3.is_empty())
						return
				else:
					_mp3.append_array(parse_audio_frame(pkt))
		WebSocketPeer.STATE_CLOSED:
			# 服务端提前关连接（403/协议变更）：有音频算成功尾包，没有算失败
			_finish(not _mp3.is_empty())

func _finish(ok: bool) -> PackedByteArray:
	if _ws != null:
		if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_ws.close()
		_ws = null
	set_process(false)
	_busy = false
	if not ok:
		available = false # 失败即降级；调用方按需重探
	_synth_done.emit(ok)
	return PackedByteArray()

func _user_agent() -> String:
	var major := CHROMIUM_FULL.split(".")[0]
	return ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
		+ "Chrome/%s.0.0.0 Safari/537.36 Edg/%s.0.0.0") % [major, major]

func _base_headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: " + _user_agent(), "Accept: */*"])

## JS 风格 UTC 时间串（协议要求的 X-Timestamp 形状）。
func _js_date() -> String:
	const WD := ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
	const MO := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var d := Time.get_datetime_dict_from_system(true)
	return "%s %s %02d %d %02d:%02d:%02d GMT+0000 (Coordinated Universal Time)" % [
		WD[d["weekday"]], MO[d["month"] - 1], d["day"], d["year"], d["hour"], d["minute"], d["second"]]
