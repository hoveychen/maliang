// iOS 平台原生桥：麦克风权限查询。
// 只在 platform=ios 时随 SConstruct 的 src/*.mm 编入（其它平台不编，maliang_asr.cpp 也不引用本符号）。
//
// 为什么要原生：Godot/GDScript 在 iOS 上读不到麦克风授权状态（不像 Android 有
// OS.get_granted_permissions），而「权限被拒」与「采音坏」在数据上都表现为 PCM 全零、无法区分。
// AVAudioSession.recordPermission 是 iOS 15.1+ 就有的稳定 API（iOS 17 起 AVAudioApplication 是新家，
// 但旧 API 仍可用），给 MicPermission 门禁一个确定的判据。

#import <AVFoundation/AVFoundation.h>

// 返回：0=未决定（系统还没弹过框）/ 1=已拒绝 / 2=已授予。
extern "C" int maliang_ios_mic_permission_status() {
	AVAudioSessionRecordPermission perm = [[AVAudioSession sharedInstance] recordPermission];
	switch (perm) {
		case AVAudioSessionRecordPermissionGranted:
			return 2;
		case AVAudioSessionRecordPermissionDenied:
			return 1;
		case AVAudioSessionRecordPermissionUndetermined:
		default:
			return 0;
	}
}
