extends SceneTree
## 端到端：喂真实中文 wav 给 GDExtension 的 sherpa 识别器，断言 final_result 正确。
## 结果写文件（MALIANG_ASR_CHECK_OUT），不依赖 stdout——导出的 release .app 不向终端打印。
## 音频与模型经 MALIANG_ASR_MODEL_DIR 指定（editor 测试与签名 app 识别验证共用）。

const CHUNK_BYTES := 4800 # 150ms @ 16k/16bit
const EXPECT_SUBSTR := "研究"
const MAX_FRAMES := 1800 # ~30s @ 60fps 的兜底

var _asr: Object
var _final := ""
var _got := false
var _frames := 0
var _out := ""

func _initialize() -> void:
	_out = OS.get_environment("MALIANG_ASR_CHECK_OUT")
	if not Engine.has_singleton("MaliangAsr"):
		_write("FAIL has_singleton=false（GDExtension 未加载）")
		quit(1); return
	_asr = Engine.get_singleton("MaliangAsr")
	_asr.connect("final_result", func(t): _final = t; _got = true)
	_asr.connect("asr_error", func(m): _write("FAIL asr_error=" + m); quit(1))
	_asr.connect("asr_ready", _on_ready)
	_asr.initialize()

func _on_ready() -> void:
	var wav := OS.get_environment("MALIANG_ASR_MODEL_DIR").path_join("test_wavs/DEV_T0000000000.wav")
	var pcm := _read_wav_pcm(wav)
	if pcm.is_empty():
		_write("FAIL 读不到 wav：" + wav); quit(1); return
	_asr.start_session()
	var off := 0
	while off < pcm.size():
		_asr.feed_pcm(pcm.slice(off, min(off + CHUNK_BYTES, pcm.size())))
		off += CHUNK_BYTES
	_asr.stop_session()

func _process(_dt: float) -> bool:
	_frames += 1
	if _got:
		if _final.find(EXPECT_SUBSTR) >= 0:
			_write("PASS " + _final); quit(0)
		else:
			_write("FAIL 文本不含「%s」：%s" % [EXPECT_SUBSTR, _final]); quit(1)
		return true
	if _frames > MAX_FRAMES:
		_write("FAIL 超时未收到 final_result（frames=%d）" % _frames); quit(1)
		return true
	return false

func _write(msg: String) -> void:
	if _out.is_empty():
		printerr(msg); return
	var f := FileAccess.open(_out, FileAccess.WRITE)
	if f != null:
		f.store_line(msg); f.flush(); f.close()

func _read_wav_pcm(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var all := f.get_buffer(f.get_length())
	f.close()
	for i in range(12, all.size() - 4):
		if all[i] == 0x64 and all[i+1] == 0x61 and all[i+2] == 0x74 and all[i+3] == 0x61:
			return all.slice(i + 8)
	return PackedByteArray()
