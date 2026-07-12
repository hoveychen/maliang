class_name PosCodec
extends RefCounted
## 位置流二进制编解码(必修②块B)。严格镜像服务端 server/src/pos_codec.ts 的帧布局(小端)。
## 生产用:encode_report(上行) + decode_relay(下行)。encode_relay/decode_report 供 round-trip 测试对拍。
## 字符串一律 u8 长度前缀 + UTF8。能力协商见 backend.gd(full_url ?posbin=1)与 world_state.posBin。

const TAG_RELAY := 0xB1   # 下行 positions_relay
const TAG_REPORT := 0xB2  # 上行 positions_report
const VERSION := 1

## 上行:编码 positions_report。chars=[{id,x,y,tileX,tileY}], player={x,y,tileX,tileY}(空 Dictionary=无)。
static func encode_report(scene_id: String, t: int, chars: Array, player: Dictionary) -> PackedByteArray:
	var scene := scene_id.to_utf8_buffer()
	assert(scene.size() <= 255, "sceneId 超 255 字节")
	var id_bufs: Array = []
	for c in chars:
		var idb: PackedByteArray = String(c.get("id", "")).to_utf8_buffer()
		assert(idb.size() <= 255, "id 超 255 字节")
		id_bufs.append(idb)
	var has_player := not player.is_empty()

	var size := 1 + 1 + 1 + scene.size() + 8 + 2
	for idb in id_bufs:
		size += 1 + (idb as PackedByteArray).size() + 4 + 4 + 2 + 2
	size += 1
	if has_player:
		size += 4 + 4 + 2 + 2

	var buf := PackedByteArray()
	buf.resize(size)
	var o := 0
	buf.encode_u8(o, TAG_REPORT); o += 1
	buf.encode_u8(o, VERSION); o += 1
	buf.encode_u8(o, scene.size()); o += 1
	for i in range(scene.size()): buf[o + i] = scene[i]
	o += scene.size()
	buf.encode_double(o, float(t)); o += 8
	buf.encode_u16(o, id_bufs.size()); o += 2
	for i in range(chars.size()):
		var idb: PackedByteArray = id_bufs[i]
		var c: Dictionary = chars[i]
		buf.encode_u8(o, idb.size()); o += 1
		for j in range(idb.size()): buf[o + j] = idb[j]
		o += idb.size()
		buf.encode_float(o, float(c.get("x", 0.0))); o += 4
		buf.encode_float(o, float(c.get("y", 0.0))); o += 4
		buf.encode_s16(o, int(c.get("tileX", 0))); o += 2
		buf.encode_s16(o, int(c.get("tileY", 0))); o += 2
	if has_player:
		buf.encode_u8(o, 1); o += 1
		buf.encode_float(o, float(player.get("x", 0.0))); o += 4
		buf.encode_float(o, float(player.get("y", 0.0))); o += 4
		buf.encode_s16(o, int(player.get("tileX", 0))); o += 2
		buf.encode_s16(o, int(player.get("tileY", 0))); o += 2
	else:
		buf.encode_u8(o, 0); o += 1
	return buf

## 下行:解码 positions_relay → {t, sceneId, chars:[{id,x,y}], player:{id,x,y}或空}。tag 不符返回空 Dictionary。
static func decode_relay(buf: PackedByteArray) -> Dictionary:
	if buf.size() < 12 or buf.decode_u8(0) != TAG_RELAY:
		return {}
	var o := 1
	o += 1 # version
	var t := int(buf.decode_double(o)); o += 8
	var scene_len := buf.decode_u8(o); o += 1
	var scene_id := buf.slice(o, o + scene_len).get_string_from_utf8(); o += scene_len
	var char_count := buf.decode_u16(o); o += 2
	var chars: Array = []
	for i in range(char_count):
		var id_len := buf.decode_u8(o); o += 1
		var id := buf.slice(o, o + id_len).get_string_from_utf8(); o += id_len
		var x := buf.decode_float(o); o += 4
		var y := buf.decode_float(o); o += 4
		chars.append({ "id": id, "x": x, "y": y })
	var has_player := buf.decode_u8(o); o += 1
	var out := { "t": t, "sceneId": scene_id, "chars": chars }
	if has_player == 1:
		var id_len := buf.decode_u8(o); o += 1
		var id := buf.slice(o, o + id_len).get_string_from_utf8(); o += id_len
		var x := buf.decode_float(o); o += 4
		var y := buf.decode_float(o); o += 4
		out["player"] = { "id": id, "x": x, "y": y }
	return out

## 供测试对拍:编码 relay(镜像服务端 encodeRelay)。
static func encode_relay(t: int, scene_id: String, chars: Array, player: Dictionary) -> PackedByteArray:
	var scene := scene_id.to_utf8_buffer()
	var id_bufs: Array = []
	for c in chars:
		id_bufs.append(String(c.get("id", "")).to_utf8_buffer())
	var has_player := not player.is_empty()
	var pid := (String(player.get("id", "")).to_utf8_buffer()) if has_player else PackedByteArray()

	var size := 1 + 1 + 8 + 1 + scene.size() + 2
	for idb in id_bufs:
		size += 1 + (idb as PackedByteArray).size() + 4 + 4
	size += 1
	if has_player:
		size += 1 + pid.size() + 4 + 4

	var buf := PackedByteArray()
	buf.resize(size)
	var o := 0
	buf.encode_u8(o, TAG_RELAY); o += 1
	buf.encode_u8(o, VERSION); o += 1
	buf.encode_double(o, float(t)); o += 8
	buf.encode_u8(o, scene.size()); o += 1
	for i in range(scene.size()): buf[o + i] = scene[i]
	o += scene.size()
	buf.encode_u16(o, id_bufs.size()); o += 2
	for i in range(chars.size()):
		var idb: PackedByteArray = id_bufs[i]
		var c: Dictionary = chars[i]
		buf.encode_u8(o, idb.size()); o += 1
		for j in range(idb.size()): buf[o + j] = idb[j]
		o += idb.size()
		buf.encode_float(o, float(c.get("x", 0.0))); o += 4
		buf.encode_float(o, float(c.get("y", 0.0))); o += 4
	if has_player:
		buf.encode_u8(o, 1); o += 1
		buf.encode_u8(o, pid.size()); o += 1
		for j in range(pid.size()): buf[o + j] = pid[j]
		o += pid.size()
		buf.encode_float(o, float(player.get("x", 0.0))); o += 4
		buf.encode_float(o, float(player.get("y", 0.0))); o += 4
	else:
		buf.encode_u8(o, 0); o += 1
	return buf

## 供测试对拍:解码 report(镜像服务端 decodeReport)。
static func decode_report(buf: PackedByteArray) -> Dictionary:
	if buf.size() < 5 or buf.decode_u8(0) != TAG_REPORT:
		return {}
	var o := 1
	o += 1 # version
	var scene_len := buf.decode_u8(o); o += 1
	var scene_id := buf.slice(o, o + scene_len).get_string_from_utf8(); o += scene_len
	var t := int(buf.decode_double(o)); o += 8
	var char_count := buf.decode_u16(o); o += 2
	var chars: Array = []
	for i in range(char_count):
		var id_len := buf.decode_u8(o); o += 1
		var id := buf.slice(o, o + id_len).get_string_from_utf8(); o += id_len
		var x := buf.decode_float(o); o += 4
		var y := buf.decode_float(o); o += 4
		var tx := buf.decode_s16(o); o += 2
		var ty := buf.decode_s16(o); o += 2
		chars.append({ "id": id, "x": x, "y": y, "tileX": tx, "tileY": ty })
	var has_player := buf.decode_u8(o); o += 1
	var out := { "sceneId": scene_id, "t": t, "chars": chars }
	if has_player == 1:
		var x := buf.decode_float(o); o += 4
		var y := buf.decode_float(o); o += 4
		var tx := buf.decode_s16(o); o += 2
		var ty := buf.decode_s16(o); o += 2
		out["player"] = { "x": x, "y": y, "tileX": tx, "tileY": ty }
	return out
