// 位置流二进制编解码(必修②块B,设计 docs/scaling-architecture-design.md §5)。
// 只编码两类高频消息:下行 positions_relay(0xB1)、上行 positions_report(0xB2)。
// 全程小端,与 Godot PackedByteArray encode_*/decode_*(小端) 对齐;客户端对应实现 scripts/pos_codec.gd。
// 字符串一律 u8 长度前缀 + UTF8(id/sceneId 均短,<256 字节)。能力协商见 server.ts(?posbin=1 + world_state.posBin)。

export const POS_TAG_RELAY = 0xb1; // 下行:服务端→客户端复制位置
export const POS_TAG_REPORT = 0xb2; // 上行:客户端→服务端位置上报
const POS_VERSION = 1;

export interface RelayChar { id: string; x: number; y: number }
export interface RelayMsg { t: number; sceneId: string; chars: RelayChar[]; player?: { id: string; x: number; y: number } }
export interface ReportChar { id: string; x: number; y: number; tileX: number; tileY: number }
export interface ReportMsg { sceneId: string; t: number; chars: ReportChar[]; player?: { x: number; y: number; tileX: number; tileY: number } }

function strBytes(s: string): Buffer {
  const b = Buffer.from(s, 'utf8');
  if (b.length > 255) throw new Error(`pos_codec: 字符串超 255 字节 (${b.length})`);
  return b;
}

/** 编码下行 positions_relay 为二进制帧。 */
export function encodeRelay(msg: RelayMsg): Buffer {
  const scene = strBytes(msg.sceneId);
  const charBufs = msg.chars.map((c) => ({ id: strBytes(c.id), c }));
  const playerId = msg.player ? strBytes(msg.player.id) : null;
  // 预算:tag(1)+ver(1)+t(8)+sceneLen(1)+scene + charCount(2) + Σ(idLen1+id+x4+y4) + hasPlayer(1) [+ idLen1+id+x4+y4]
  let size = 1 + 1 + 8 + 1 + scene.length + 2;
  for (const { id } of charBufs) size += 1 + id.length + 4 + 4;
  size += 1;
  if (playerId) size += 1 + playerId.length + 4 + 4;

  const buf = Buffer.allocUnsafe(size);
  let o = 0;
  buf.writeUInt8(POS_TAG_RELAY, o); o += 1;
  buf.writeUInt8(POS_VERSION, o); o += 1;
  buf.writeDoubleLE(msg.t, o); o += 8;
  buf.writeUInt8(scene.length, o); o += 1;
  scene.copy(buf, o); o += scene.length;
  buf.writeUInt16LE(charBufs.length, o); o += 2;
  for (const { id, c } of charBufs) {
    buf.writeUInt8(id.length, o); o += 1;
    id.copy(buf, o); o += id.length;
    buf.writeFloatLE(c.x, o); o += 4;
    buf.writeFloatLE(c.y, o); o += 4;
  }
  if (playerId && msg.player) {
    buf.writeUInt8(1, o); o += 1;
    buf.writeUInt8(playerId.length, o); o += 1;
    playerId.copy(buf, o); o += playerId.length;
    buf.writeFloatLE(msg.player.x, o); o += 4;
    buf.writeFloatLE(msg.player.y, o); o += 4;
  } else {
    buf.writeUInt8(0, o); o += 1;
  }
  return buf;
}

/** 解码下行 positions_relay(客户端侧对应实现在 GDScript;此处供测试对拍)。 */
export function decodeRelay(buf: Buffer): RelayMsg {
  let o = 0;
  const tag = buf.readUInt8(o); o += 1;
  if (tag !== POS_TAG_RELAY) throw new Error(`pos_codec: relay tag 不符 0x${tag.toString(16)}`);
  o += 1; // version
  const t = buf.readDoubleLE(o); o += 8;
  const sceneLen = buf.readUInt8(o); o += 1;
  const sceneId = buf.toString('utf8', o, o + sceneLen); o += sceneLen;
  const charCount = buf.readUInt16LE(o); o += 2;
  const chars: RelayChar[] = [];
  for (let i = 0; i < charCount; i++) {
    const idLen = buf.readUInt8(o); o += 1;
    const id = buf.toString('utf8', o, o + idLen); o += idLen;
    const x = buf.readFloatLE(o); o += 4;
    const y = buf.readFloatLE(o); o += 4;
    chars.push({ id, x, y });
  }
  const hasPlayer = buf.readUInt8(o); o += 1;
  let player: RelayMsg['player'];
  if (hasPlayer) {
    const idLen = buf.readUInt8(o); o += 1;
    const id = buf.toString('utf8', o, o + idLen); o += idLen;
    const x = buf.readFloatLE(o); o += 4;
    const y = buf.readFloatLE(o); o += 4;
    player = { id, x, y };
  }
  return { t, sceneId, chars, player };
}

/** 解码上行 positions_report(服务端收客户端二进制帧)。worldId 不在帧内,由 hub.worldOf 决定。 */
export function decodeReport(buf: Buffer): ReportMsg {
  let o = 0;
  const tag = buf.readUInt8(o); o += 1;
  if (tag !== POS_TAG_REPORT) throw new Error(`pos_codec: report tag 不符 0x${tag.toString(16)}`);
  o += 1; // version
  const sceneLen = buf.readUInt8(o); o += 1;
  const sceneId = buf.toString('utf8', o, o + sceneLen); o += sceneLen;
  const t = buf.readDoubleLE(o); o += 8;
  const charCount = buf.readUInt16LE(o); o += 2;
  const chars: ReportChar[] = [];
  for (let i = 0; i < charCount; i++) {
    const idLen = buf.readUInt8(o); o += 1;
    const id = buf.toString('utf8', o, o + idLen); o += idLen;
    const x = buf.readFloatLE(o); o += 4;
    const y = buf.readFloatLE(o); o += 4;
    const tileX = buf.readInt16LE(o); o += 2;
    const tileY = buf.readInt16LE(o); o += 2;
    chars.push({ id, x, y, tileX, tileY });
  }
  const hasPlayer = buf.readUInt8(o); o += 1;
  let player: ReportMsg['player'];
  if (hasPlayer) {
    const x = buf.readFloatLE(o); o += 4;
    const y = buf.readFloatLE(o); o += 4;
    const tileX = buf.readInt16LE(o); o += 2;
    const tileY = buf.readInt16LE(o); o += 2;
    player = { x, y, tileX, tileY };
  }
  return { sceneId, t, chars, player };
}

/** 编码上行 positions_report(供客户端对拍;真实上行编码在 GDScript)。 */
export function encodeReport(msg: ReportMsg): Buffer {
  const scene = strBytes(msg.sceneId);
  const charBufs = msg.chars.map((c) => ({ id: strBytes(c.id), c }));
  let size = 1 + 1 + 1 + scene.length + 8 + 2;
  for (const { id } of charBufs) size += 1 + id.length + 4 + 4 + 2 + 2;
  size += 1;
  if (msg.player) size += 4 + 4 + 2 + 2;

  const buf = Buffer.allocUnsafe(size);
  let o = 0;
  buf.writeUInt8(POS_TAG_REPORT, o); o += 1;
  buf.writeUInt8(POS_VERSION, o); o += 1;
  buf.writeUInt8(scene.length, o); o += 1;
  scene.copy(buf, o); o += scene.length;
  buf.writeDoubleLE(msg.t, o); o += 8;
  buf.writeUInt16LE(charBufs.length, o); o += 2;
  for (const { id, c } of charBufs) {
    buf.writeUInt8(id.length, o); o += 1;
    id.copy(buf, o); o += id.length;
    buf.writeFloatLE(c.x, o); o += 4;
    buf.writeFloatLE(c.y, o); o += 4;
    buf.writeInt16LE(c.tileX, o); o += 2;
    buf.writeInt16LE(c.tileY, o); o += 2;
  }
  if (msg.player) {
    buf.writeUInt8(1, o); o += 1;
    buf.writeFloatLE(msg.player.x, o); o += 4;
    buf.writeFloatLE(msg.player.y, o); o += 4;
    buf.writeInt16LE(msg.player.tileX, o); o += 2;
    buf.writeInt16LE(msg.player.tileY, o); o += 2;
  } else {
    buf.writeUInt8(0, o); o += 1;
  }
  return buf;
}
