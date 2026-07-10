#pragma once

#include <godot_cpp/classes/object.hpp>
#include <godot_cpp/core/class_db.hpp>

namespace godot {

// 端侧 ASR 的 macOS/桌面实现（GDExtension）。与 Android 的 MaliangAsr 插件同名同接口，
// 客户端 world.gd / onboarding.gd 通过 Engine.has_singleton("MaliangAsr") 拿到本单例，
// 两平台走完全一致的分支逻辑（见 docs/macos-asr-feasibility.md）。
//
// P1 为最小骨架：只验证 Godot 4.6 能在 macOS 加载 GDExtension 并暴露单例；
// 尚未接 sherpa，故 is_ready() 恒为 false（客户端据此仍走服务端识别，不误伤）。
// P2 会把 Kotlin 插件那套 sherpa OnlineRecognizer 直译进来。
class MaliangAsr : public Object {
	GDCLASS(MaliangAsr, Object)

protected:
	static void _bind_methods();

public:
	// P1 桩：模型未接，恒未就绪。P2 起返回真实加载状态。
	bool is_ready() const;
	// 探针：证明本单例确由 GDExtension 提供（非 GDScript 伪造）。P2 后可删。
	String backend() const;

	MaliangAsr();
	~MaliangAsr();
};

} // namespace godot
