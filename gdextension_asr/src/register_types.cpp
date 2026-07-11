#include "register_types.h"

#include "maliang_asr.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

#include <gdextension_interface.h>

using namespace godot;

static MaliangAsr *_maliang_asr_singleton = nullptr;

void initialize_maliang_asr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	ClassDB::register_class<MaliangAsr>();
	// 注册为引擎单例，客户端 Engine.get_singleton("MaliangAsr") 即可取到（与 Android 一致）。
	_maliang_asr_singleton = memnew(MaliangAsr);
	Engine::get_singleton()->register_singleton("MaliangAsr", _maliang_asr_singleton);
}

void uninitialize_maliang_asr_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	Engine::get_singleton()->unregister_singleton("MaliangAsr");
	if (_maliang_asr_singleton != nullptr) {
		memdelete(_maliang_asr_singleton);
		_maliang_asr_singleton = nullptr;
	}
}

extern "C" {
GDExtensionBool GDE_EXPORT maliang_asr_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_maliang_asr_module);
	init_obj.register_terminator(uninitialize_maliang_asr_module);
	init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
