extends SceneTree
## P2 端到端：喂真实中文 wav 给 GDExtension 的 sherpa 识别器，断言 final_result 正确。
## 跑法（模型经 env 指向 server/models）：
##   MALIANG_ASR_MODEL_DIR=<abs>/server/models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12 \
##   Godot --headless --path <worktree> --script res://test/macos_asr_recognize.gd
## 成功打印 "[P2 PASS] <识别文本>" 并 quit(0)。

const CHUNK_BYTES := 4800 # 150ms @ 16k/16bit，与客户端 feedPcm 批大小一致
# 期望文本的关键片段（模型自带样音 DEV_T0000000000 的稳定转写）
const EXPECT_SUBSTR := "研究"

var _asr: Object
var _final := ""
var _got_final := false
var _elapsed := 0.0

func _initialize() -> void:
	if not Engine.has_singleton("MaliangAsr"):
		_fail("MaliangAsr 单例不存在（GDExtension 未加载）")
		return
	_asr = Engine.get_singleton("MaliangAsr")
	_asr.connect("asr_ready", _on_ready)
	_asr.connect("final_result", _on_final)
	_asr.connect("asr_error", _on_error)
	print("[P2] initialize() ...")
	_asr.initialize()

func _on_ready() -> void:
	print("[P2] asr_ready，is_ready=%s，开始喂音频" % _asr.is_ready())
	if not _asr.is_ready():
		_fail("asr_ready 后 is_ready() 仍为 false")
		return
	var wav := OS.get_environment("MALIANG_ASR_MODEL_DIR").path_join("test_wavs/DEV_T0000000000.wav")
	var pcm := _read_wav_pcm(wav)
	if pcm.is_empty():
		_fail("读不到测试音频 PCM：" + wav)
		return
	_asr.start_session()
	var off := 0
	while off < pcm.size():
		_asr.feed_pcm(pcm.slice(off, min(off + CHUNK_BYTES, pcm.size())))
		off += CHUNK_BYTES
	_asr.stop_session()

func _on_final(text: String) -> void:
	_final = text
	_got_final = true

func _on_error(msg: String) -> void:
	_fail("asr_error: " + msg)

# SceneTree 每帧回调：等 final_result 回来（deferred 信号需主循环 flush）。
func _process(delta: float) -> bool:
	_elapsed += delta
	if _got_final:
		if _final.find(EXPECT_SUBSTR) >= 0:
			print("[P2 PASS] 端侧识别：「%s」" % _final)
			quit(0)
		else:
			_fail("识别文本不含期望片段「%s」，实际：「%s」" % [EXPECT_SUBSTR, _final])
		return true
	if _elapsed > 30.0:
		_fail("30s 内未收到 final_result")
		return true
	return false

func _read_wav_pcm(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var all := f.get_buffer(f.get_length())
	f.close()
	# 跳到 "data" chunk 后的 PCM（16k/mono/16bit wav）
	var data_pos := -1
	for i in range(12, all.size() - 4):
		if all[i] == 0x64 and all[i + 1] == 0x61 and all[i + 2] == 0x74 and all[i + 3] == 0x61:
			data_pos = i + 8
			break
	if data_pos < 0:
		return PackedByteArray()
	return all.slice(data_pos)

func _fail(msg: String) -> void:
	push_error("[P2 FAIL] " + msg)
	printerr("[P2 FAIL] " + msg)
	quit(1)
