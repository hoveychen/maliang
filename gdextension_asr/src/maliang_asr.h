#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <atomic>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>

// sherpa-onnx C API 前置声明（避免头文件里泄露 sherpa 类型）。
struct SherpaOnnxOnlineRecognizer;
struct SherpaOnnxOnlineStream;

namespace godot {

// 端侧流式中文 ASR 的 macOS/桌面实现（GDExtension），直译自 Android 的
// asr_plugin/.../MaliangAsrPlugin.kt：同名单例 MaliangAsr、同方法名同信号，
// 客户端 world.gd / onboarding.gd 零改动（见 docs/macos-asr-feasibility.md）。
//
// 生命周期：initialize()（异步加载模型 → asr_ready）→ start_session
// → feed_pcm(16k PCM16LE)×N → stop_session（补尾静音 → final_result）。
// 所有 sherpa 推理都在单一后台线程（_worker）上跑，GDScript 侧只搬字节，
// 绝不阻塞主线程/音频线程；信号一律 call_deferred 回主线程发射（跨线程 emit 不安全）。
class MaliangAsr : public Object {
	GDCLASS(MaliangAsr, Object)

protected:
	static void _bind_methods();

public:
	// 异步加载模型（~秒级），完成发 asr_ready；失败发 asr_error。幂等。
	void initialize();
	// 模型已就绪则可走端侧；GDScript 据此决定端侧/服务端路由。
	bool is_ready() const;
	// 开一段新的识别会话（丢弃上一段）。
	void start_session();
	// 16kHz 单声道 PCM16LE 分片（与服务端 voice_chunk 同一采集源）。
	void feed_pcm(const PackedByteArray &chunk);
	// 收尾：补 0.6s 静音吐出最后几个字，发 final_result 并释放会话。
	void stop_session();

	MaliangAsr();
	~MaliangAsr();

private:
	// —— 后台单线程执行器（对应 Kotlin 的 Executors.newSingleThreadExecutor）——
	std::thread _worker;
	std::mutex _mutex;
	std::condition_variable _cv;
	std::queue<std::function<void()>> _tasks;
	std::atomic<bool> _shutdown{ false };
	void _enqueue(std::function<void()> task);
	void _worker_loop();

	// —— sherpa 句柄（仅在 _worker 线程上访问）——
	const SherpaOnnxOnlineRecognizer *_recognizer = nullptr;
	const SherpaOnnxOnlineStream *_stream = nullptr;
	std::atomic<bool> _ready{ false }; // 供主线程 is_ready() 无锁读
	String _last_partial;

	// 解析模型目录：env MALIANG_ASR_MODEL_DIR 优先，否则 .app 内置路径。
	String _resolve_model_dir() const;
	// 线程安全地发信号（marshal 回主线程）。
	void _emit_deferred(const String &signal, const Variant &arg = Variant());
};

} // namespace godot
