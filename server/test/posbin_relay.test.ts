import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WorldHub, type HubMember } from '../src/world_hub.ts';
import { WorldStore } from '../src/persistence.ts';
import { applyPositionsReport, newVoiceSession } from '../src/server.ts';
import { decodeRelay } from '../src/pos_codec.ts';
import { DEFAULT_SCENE } from '../src/types.ts';

// 双格式分发:posBin 成员收二进制帧、老成员收 JSON 文本,同一份内容各编码一次。
test('positions_relay 双格式: posBin 成员收 bin, 老成员收 JSON', () => {
  const store = new WorldStore();
  store.createWorld('w1');
  const hub = new WorldHub();

  let binMember: Uint8Array | null = null;
  const textMember: string[] = [];
  const memBin: HubMember = {
    clientId: 'cA', playerId: 'pA', sceneId: DEFAULT_SCENE,
    send: () => {}, sendText: () => { throw new Error('posBin 成员不该收文本'); },
    posBin: true, sendBin: (b) => { binMember = b as Uint8Array; },
  };
  const memText: HubMember = {
    clientId: 'cB', playerId: 'pB', sceneId: DEFAULT_SCENE,
    send: () => {}, sendText: (s) => textMember.push(s),
    posBin: false, sendBin: () => { throw new Error('老成员不该收二进制'); },
  };
  hub.join('w1', memBin);
  hub.join('w1', memText);

  // 报告者 cC(排除自己),携玩家世界坐标 + tile。
  const session = newVoiceSession();
  session.playerId = 'pC';
  session.currentScene = DEFAULT_SCENE;
  const socket = { send: () => {} };
  applyPositionsReport(
    { worldId: 'w1', sceneId: '', t: 5000, chars: [], player: { x: 12.5, y: -3.25, tileX: 4, tileY: 5 } },
    socket, store, session, 'cC', hub,
  );

  // posBin 成员:二进制帧解码回原值(以 playerId 为 actor 键)。
  assert.ok(binMember, 'posBin 成员应收到二进制帧');
  const dec = decodeRelay(Buffer.from(binMember!));
  assert.equal(dec.t, 5000);
  assert.deepEqual(dec.player, { id: 'pC', x: 12.5, y: -3.25 });

  // 老成员:JSON 文本 positions_relay。
  assert.equal(textMember.length, 1, '老成员收一条文本');
  const j = JSON.parse(textMember[0]);
  assert.equal(j.type, 'positions_relay');
  assert.deepEqual(j.player, { id: 'pC', x: 12.5, y: -3.25 });
});
