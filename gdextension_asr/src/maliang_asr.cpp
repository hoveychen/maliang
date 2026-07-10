#include "maliang_asr.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void MaliangAsr::_bind_methods() {
	ClassDB::bind_method(D_METHOD("is_ready"), &MaliangAsr::is_ready);
	ClassDB::bind_method(D_METHOD("backend"), &MaliangAsr::backend);

	// P2 会补齐与 Android 插件对齐的信号：asr_ready / partial_result / final_result / asr_error，
	// 及 initialize / start_session / feed_pcm / stop_session 方法。
}

bool MaliangAsr::is_ready() const {
	return false; // P1：sherpa 未接，恒未就绪。
}

String MaliangAsr::backend() const {
	return "gdextension-stub"; // 探针：证明单例来自本原生扩展。
}

MaliangAsr::MaliangAsr() {}
MaliangAsr::~MaliangAsr() {}
