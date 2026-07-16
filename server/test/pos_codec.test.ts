import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  encodeRelay, decodeRelay, encodeReport, decodeReport,
  POS_TAG_RELAY, POS_TAG_REPORT,
  type RelayMsg, type ReportMsg,
} from '../src/pos_codec.ts';

// x/y 用 float32 可精确表示的值(整数/半数),round-trip 后严格相等。
test('relay round-trip: 多角色 + player', () => {
  const msg: RelayMsg = {
    t: 1234567,
    sceneId: 'seafloor',
    chars: [
      { id: 'char-abc', x: 12.5, y: -3.25 },
      { id: '角色汉字id', x: 0, y: 74.5 },
    ],
    player: { id: 'player-uuid-xyz', x: 37, y: 37.75 },
  };
  const dec = decodeRelay(encodeRelay(msg));
  assert.deepEqual(dec, msg);
});

test('relay round-trip: 空 chars 无 player', () => {
  const msg: RelayMsg = { t: 0, sceneId: 'village', chars: [] };
  const dec = decodeRelay(encodeRelay(msg));
  assert.deepEqual(dec, { t: 0, sceneId: 'village', chars: [], player: undefined });
});

test('report round-trip: 多角色 + player(带 tile)', () => {
  const msg: ReportMsg = {
    sceneId: 'forest',
    t: 999,
    chars: [
      { id: 'npc1', x: 1.5, y: 2.5, tileX: 3, tileY: 4 },
      { id: 'npc2', x: -10.25, y: 5, tileX: -1, tileY: 74 },
    ],
    player: { x: 20, y: 21.5, tileX: 10, tileY: 11 },
  };
  const dec = decodeReport(encodeReport(msg));
  assert.deepEqual(dec, msg);
});

test('report round-trip: 只 player 无 chars', () => {
  const msg: ReportMsg = { sceneId: 'village', t: 42, chars: [], player: { x: 0, y: 0, tileX: 0, tileY: 0 } };
  const dec = decodeReport(encodeReport(msg));
  assert.deepEqual(dec, msg);
});

test('tag 头正确 + 错 tag 抛错', () => {
  assert.equal(encodeRelay({ t: 0, sceneId: 'v', chars: [] })[0], POS_TAG_RELAY);
  assert.equal(encodeReport({ sceneId: 'v', t: 0, chars: [] })[0], POS_TAG_REPORT);
  // 把 relay 帧丢给 decodeReport 应抛错(tag 不符),不静默错位解析
  assert.throws(() => decodeReport(encodeRelay({ t: 0, sceneId: 'v', chars: [] })));
});
