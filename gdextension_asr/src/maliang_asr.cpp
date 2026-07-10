#include "maliang_asr.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "sherpa-onnx/c-api/c-api.h"

#include <cstring>
#include <string>
#include <vector>

using namespace godot;

// 与 Android 插件、服务端 local.ts 完全同一套权重（int8 encoder/joiner + fp32 decoder）。
static const char *ASR_MODEL_DIR = "sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12";
static const int SAMPLE_RATE = 16000;

void MaliangAsr::_bind_methods() {
	ClassDB::bind_method(D_METHOD("initialize"), &MaliangAsr::initialize);
	ClassDB::bind_method(D_METHOD("is_ready"), &MaliangAsr::is_ready);
	ClassDB::bind_method(D_METHOD("isReady"), &MaliangAsr::is_ready); // Android 侧驼峰名，兼容客户端现有调用
	ClassDB::bind_method(D_METHOD("start_session"), &MaliangAsr::start_session);
	ClassDB::bind_method(D_METHOD("startSession"), &MaliangAsr::start_session);
	ClassDB::bind_method(D_METHOD("feed_pcm", "chunk"), &MaliangAsr::feed_pcm);
	ClassDB::bind_method(D_METHOD("feedPcm", "chunk"), &MaliangAsr::feed_pcm);
	ClassDB::bind_method(D_METHOD("stop_session"), &MaliangAsr::stop_session);
	ClassDB::bind_method(D_METHOD("stopSession"), &MaliangAsr::stop_session);

	// 与 Android 插件对齐的信号（world.gd 连接 final_result/asr_error/asr_ready）。
	ADD_SIGNAL(MethodInfo("asr_ready"));
	ADD_SIGNAL(MethodInfo("partial_result", PropertyInfo(Variant::STRING, "text")));
	ADD_SIGNAL(MethodInfo("final_result", PropertyInfo(Variant::STRING, "text")));
	ADD_SIGNAL(MethodInfo("asr_error", PropertyInfo(Variant::STRING, "message")));
}

MaliangAsr::MaliangAsr() {
	_worker = std::thread(&MaliangAsr::_worker_loop, this);
}

MaliangAsr::~MaliangAsr() {
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_shutdown = true;
	}
	_cv.notify_all();
	if (_worker.joinable()) {
		_worker.join();
	}
	// 线程退出后再释放 sherpa 句柄（仅本线程碰过它们；此时已 join）。
	if (_stream != nullptr) {
		SherpaOnnxDestroyOnlineStream(_stream);
		_stream = nullptr;
	}
	if (_recognizer != nullptr) {
		SherpaOnnxDestroyOnlineRecognizer(_recognizer);
		_recognizer = nullptr;
	}
}

void MaliangAsr::_enqueue(std::function<void()> task) {
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_tasks.push(std::move(task));
	}
	_cv.notify_one();
}

void MaliangAsr::_worker_loop() {
	for (;;) {
		std::function<void()> task;
		{
			std::unique_lock<std::mutex> lock(_mutex);
			_cv.wait(lock, [this] { return _shutdown || !_tasks.empty(); });
			if (_shutdown && _tasks.empty()) {
				return;
			}
			task = std::move(_tasks.front());
			_tasks.pop();
		}
		task();
	}
}

void MaliangAsr::_emit_deferred(const String &signal, const Variant &arg) {
	// 跨线程发信号：call_deferred 会把发射排到主线程消息队列，主循环 flush 时执行。
	if (arg.get_type() == Variant::NIL) {
		call_deferred("emit_signal", signal);
	} else {
		call_deferred("emit_signal", signal, arg);
	}
}

String MaliangAsr::_resolve_model_dir() const {
	// 测试/开发：env 直指（headless 测试用 server/models）。
	String env_dir = OS::get_singleton()->get_environment("MALIANG_ASR_MODEL_DIR");
	if (!env_dir.is_empty()) {
		return env_dir;
	}
	String exe_dir = OS::get_singleton()->get_executable_path().get_base_dir();
	// macOS .app：可执行文件在 Contents/MacOS/，模型随包放 Contents/Resources/asr-models/。
	String bundled = exe_dir.path_join("../Resources/asr-models").path_join(ASR_MODEL_DIR).simplify_path();
	if (FileAccess::file_exists(bundled.path_join("tokens.txt"))) {
		return bundled;
	}
	// 退路：可执行文件旁 asr-models/（其它平台/布局）。
	return exe_dir.path_join("asr-models").path_join(ASR_MODEL_DIR);
}

void MaliangAsr::initialize() {
	_enqueue([this] {
		if (_recognizer != nullptr) {
			_emit_deferred("asr_ready");
			return;
		}
		String dir = _resolve_model_dir();
		String encoder = dir.path_join("encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx");
		String decoder = dir.path_join("decoder-epoch-20-avg-1-chunk-16-left-128.onnx");
		String joiner = dir.path_join("joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx");
		String tokens = dir.path_join("tokens.txt");

		// 模型缺失时提前报错回落服务端（对应 Kotlin 里先 open tokens.txt 探一下）。
		if (!FileAccess::file_exists(tokens)) {
			_emit_deferred("asr_error", String("model missing: ") + tokens);
			return;
		}

		// C API 用 CharString 持有底层字节，配置期间不能析构。
		CharString c_encoder = encoder.utf8();
		CharString c_decoder = decoder.utf8();
		CharString c_joiner = joiner.utf8();
		CharString c_tokens = tokens.utf8();
		CharString c_provider = String("cpu").utf8();
		CharString c_decoding = String("greedy_search").utf8();
		CharString c_model_type = String("zipformer2").utf8();

		SherpaOnnxOnlineRecognizerConfig config;
		memset(&config, 0, sizeof(config));
		config.feat_config.sample_rate = SAMPLE_RATE;
		config.feat_config.feature_dim = 80;
		config.model_config.transducer.encoder = c_encoder.get_data();
		config.model_config.transducer.decoder = c_decoder.get_data();
		config.model_config.transducer.joiner = c_joiner.get_data();
		config.model_config.tokens = c_tokens.get_data();
		config.model_config.num_threads = 2;
		config.model_config.provider = c_provider.get_data();
		config.model_config.debug = 0;
		config.model_config.model_type = c_model_type.get_data();
		config.decoding_method = c_decoding.get_data();

		const SherpaOnnxOnlineRecognizer *rec = SherpaOnnxCreateOnlineRecognizer(&config);
		if (rec == nullptr) {
			_emit_deferred("asr_error", "SherpaOnnxCreateOnlineRecognizer failed");
			return;
		}
		_recognizer = rec;
		_ready = true;
		_emit_deferred("asr_ready");
	});
}

bool MaliangAsr::is_ready() const {
	return _ready.load();
}

void MaliangAsr::start_session() {
	_enqueue([this] {
		if (_recognizer == nullptr) {
			_emit_deferred("asr_error", "not initialized");
			return;
		}
		if (_stream != nullptr) {
			SherpaOnnxDestroyOnlineStream(_stream);
			_stream = nullptr;
		}
		_stream = SherpaOnnxCreateOnlineStream(_recognizer);
		_last_partial = "";
	});
}

void MaliangAsr::feed_pcm(const PackedByteArray &chunk) {
	// 主线程只做拷贝，推理丢给 worker。PackedByteArray 按值捕获（隐式 CoW，安全）。
	int64_t n_bytes = chunk.size();
	if (n_bytes < 2) {
		return;
	}
	// PCM16LE → float。转换放主线程也可，但为对齐 Kotlin（全在 executor）挪到 worker。
	std::vector<float> samples;
	samples.resize(n_bytes / 2);
	const uint8_t *ptr = chunk.ptr();
	for (int64_t i = 0; i < n_bytes / 2; i++) {
		int16_t s = (int16_t)((uint16_t)ptr[2 * i] | ((uint16_t)ptr[2 * i + 1] << 8));
		samples[i] = (float)s / 32768.0f;
	}
	_enqueue([this, samples = std::move(samples)]() mutable {
		if (_recognizer == nullptr || _stream == nullptr) {
			return;
		}
		SherpaOnnxOnlineStreamAcceptWaveform(_stream, SAMPLE_RATE, samples.data(), (int32_t)samples.size());
		while (SherpaOnnxIsOnlineStreamReady(_recognizer, _stream)) {
			SherpaOnnxDecodeOnlineStream(_recognizer, _stream);
		}
		const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(_recognizer, _stream);
		String text = String::utf8(r->text != nullptr ? r->text : "");
		SherpaOnnxDestroyOnlineRecognizerResult(r);
		if (!text.is_empty() && text != _last_partial) {
			_last_partial = text;
			_emit_deferred("partial_result", text);
		}
	});
}

void MaliangAsr::stop_session() {
	_enqueue([this] {
		if (_recognizer == nullptr) {
			_emit_deferred("asr_error", "not initialized");
			return;
		}
		if (_stream == nullptr) {
			_emit_deferred("asr_error", "no active session");
			return;
		}
		// 补 0.6s 静音把窗口内最后几个字吐出来（与 Kotlin/官方示例一致）。
		std::vector<float> tail(SAMPLE_RATE * 6 / 10, 0.0f);
		SherpaOnnxOnlineStreamAcceptWaveform(_stream, SAMPLE_RATE, tail.data(), (int32_t)tail.size());
		SherpaOnnxOnlineStreamInputFinished(_stream);
		while (SherpaOnnxIsOnlineStreamReady(_recognizer, _stream)) {
			SherpaOnnxDecodeOnlineStream(_recognizer, _stream);
		}
		const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(_recognizer, _stream);
		String text = String::utf8(r->text != nullptr ? r->text : "").strip_edges();
		SherpaOnnxDestroyOnlineRecognizerResult(r);
		SherpaOnnxDestroyOnlineStream(_stream);
		_stream = nullptr;
		_emit_deferred("final_result", text);
	});
}
