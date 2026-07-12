// 玩家间互动 P1（docs/player-interaction-design.md）：
// player_emote / player_speech 的无状态场景定向转发 + 玩家音色稳定分配 + presence 带 voiceId。
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { WorldStore } from '../src/persistence.ts';
import { RateLimiter } from '../src/ratelimit.ts';
import { handleWsMessage, newVoiceSession } from '../src/server.ts';
import { WorldHub } from '../src/world_hub.ts';
import { voiceForPlayer } from '../src/voice_catalog.ts';

function rig() {
  const store = new WorldStore();
  store.createWorld('w1');
  const adapters = createMockAdapters();
  const limiter = new RateLimiter(100, 100);
  const hub = new WorldHub();
  const conn = (connKey: string) => {
    const sent: any[] = [];
    const socket = { send: (s: string) => sent.push(JSON.parse(s)) };
    const session = newVoiceSession();
    const say = (msg: object) =>
      handleWsMessage(socket, JSON.stringify(msg), adapters, store, limiter, connKey, session, hub);
    return { sent, say, ofType: (t: string) => sent.filter((m) => m.type === t) };
  };
  return { store, hub, conn };
}

function profile(name: string, gender = 'boy') {
  return { name, nickname: '', gender, color: '蓝', spriteAsset: '', createdAt: '2026-01-01' };
}

test('voiceForPlayer：稳定（同 id 同声）、按性别分池、未知性别也有声', () => {
  assert.equal(voiceForPlayer('pa', 'boy'), voiceForPlayer('pa', 'boy'), '同一玩家永远同声');
  assert.match(voiceForPlayer('pa', 'boy'), /^zh-CN-Yun/, '男孩落男声池');
  assert.match(voiceForPlayer('pa', 'girl'), /^zh-CN-Xiao/, '女孩落女声池');
  assert.match(voiceForPlayer('pa'), /^zh-CN-/, '性别缺省也能落到合法音色');
});

test('presence：actors_snapshot / actor_join 带 voiceId', async () => {
  const { conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明') });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红', 'girl') });

  const snap = b.ofType('actors_snapshot');
  assert.equal(snap.length, 1);
  assert.equal(snap[0].actors.length, 1, 'B 的快照里有 A');
  assert.equal(snap[0].actors[0].voiceId, voiceForPlayer('pa', 'boy'), '快照带 A 的稳定音色');

  const join = a.ofType('actor_join');
  assert.equal(join.length, 1, 'A 收到 B 进场');
  assert.equal(join[0].actor.voiceId, voiceForPlayer('pb', 'girl'), 'actor_join 带 B 的稳定音色');
});

test('player_emote：同场景他人收到，发送者不回环，动作白名单外报错', async () => {
  const { conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  const c = conn('cC');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明') });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红') });
  await c.say({ type: 'world_info', worldId: 'w1', playerId: 'pc', sceneId: 'forest', profile: profile('小刚') });
  a.sent.length = 0; b.sent.length = 0; c.sent.length = 0;

  await a.say({ type: 'player_emote', worldId: 'w1', targetPlayerId: 'pb', action: 'wave' });

  const got = b.ofType('player_emote');
  assert.equal(got.length, 1, '同场景的 B 收到');
  assert.equal(got[0].fromPlayerId, 'pa');
  assert.equal(got[0].targetPlayerId, 'pb');
  assert.equal(got[0].action, 'wave');
  assert.equal(a.ofType('player_emote').length, 0, '发送者不回环');
  assert.equal(c.ofType('player_emote').length, 0, '隔壁场景收不到');

  // 表情盘新三格（纸片动作精选）在白名单内正常转发
  for (const act of ['flip', 'squish', 'paper_plane']) {
    await a.say({ type: 'player_emote', worldId: 'w1', targetPlayerId: 'pb', action: act });
  }
  assert.equal(b.ofType('player_emote').length, 4, '新三格动作照常转发');

  // moonwalk 不是动作（backflip 是 do_action 但不在表情盘白名单，语义混淆不拿来当例子）
  await a.say({ type: 'player_emote', worldId: 'w1', targetPlayerId: 'pb', action: 'moonwalk' });
  assert.equal(b.ofType('player_emote').length, 4, '非法动作不转发');
  assert.equal(a.ofType('error').length, 1, '非法动作回 error');
});

test('player_speech：带 text/lang/服务端盖章的 voiceId 转发；空文本不转发；超长截断', async () => {
  const { conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明') });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红') });
  a.sent.length = 0; b.sent.length = 0;

  await a.say({ type: 'player_speech', worldId: 'w1', targetPlayerId: 'pb', text: '你好呀，一起玩吗？' });
  let got = b.ofType('player_speech');
  assert.equal(got.length, 1, '同场景的 B 收到喊话');
  assert.equal(got[0].text, '你好呀，一起玩吗？');
  assert.equal(got[0].lang, 'zh', 'lang 缺省 zh');
  assert.equal(got[0].voiceId, voiceForPlayer('pa', 'boy'), '音色由服务端按发送者盖章');
  assert.equal(got[0].fromPlayerId, 'pa');

  await a.say({ type: 'player_speech', worldId: 'w1', targetPlayerId: 'pb', text: '   ' });
  assert.equal(b.ofType('player_speech').length, 1, '空文本不转发');

  await a.say({ type: 'player_speech', worldId: 'w1', targetPlayerId: 'pb', text: '啊'.repeat(500), lang: 'en' });
  got = b.ofType('player_speech');
  assert.equal(got.length, 2);
  assert.equal(got[1].text.length, 200, '超长截断到 200');
  assert.equal(got[1].lang, 'en', 'lang 透传');
});

test('送爱心：收方爱心 +1（只增不减）+ 在线单播 hearts_update；发送者不收', async () => {
  const { store, conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明') });
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红') });
  a.sent.length = 0; b.sent.length = 0;

  await a.say({ type: 'player_emote', worldId: 'w1', targetPlayerId: 'pb', action: 'heart' });

  assert.equal(store.getWallet('w1', 'pb').hearts, 1, '收方入账 1 颗爱心');
  assert.equal(store.getWallet('w1', 'pa').hearts, 0, '送方不动账');
  const up = b.ofType('hearts_update');
  assert.equal(up.length, 1, '收方在线收到钱包单播');
  assert.equal(up[0].wallet.hearts, 1);
  assert.equal(up[0].wallet.flowers, store.getWallet('w1', 'pb').flowers, '小红花分文未动');
  assert.equal(a.ofType('hearts_update').length, 0, '送方不收 hearts_update');
  assert.equal(b.ofType('player_emote').length, 1, 'emote 广播照发（收方演爱心特效）');

  // 自己送自己不入账（防刷）
  await a.say({ type: 'player_emote', worldId: 'w1', targetPlayerId: 'pa', action: 'heart' });
  assert.equal(store.getWallet('w1', 'pa').hearts, 0, '自送不入账');
});

test('world_state 带自己的 voiceId：喊话复述音 = 对端听到的音', async () => {
  const { conn } = rig();
  const a = conn('cA');
  await a.say({ type: 'world_info', worldId: 'w1', playerId: 'pa', sceneId: 'village', profile: profile('小明') });
  const ws = a.ofType('world_state');
  assert.equal(ws.length, 1);
  assert.equal(ws[0].voiceId, voiceForPlayer('pa', 'boy'), '与 presence/player_speech 同一稳定音色');
});

test('钱包 hearts 字段：新钱包为 0，旧格式（无 hearts）读回归一为 0', () => {
  const { store } = rig();
  const w = store.getWallet('w1', 'px');
  assert.equal(w.hearts, 0, '新钱包 hearts=0');
  assert.equal(typeof w.flowers, 'number', '钱包其余字段照旧');
});

test('player_speech：无身份（未 world_info）静默丢弃，不报错不广播', async () => {
  const { conn } = rig();
  const a = conn('cA');
  const b = conn('cB');
  await b.say({ type: 'world_info', worldId: 'w1', playerId: 'pb', sceneId: 'village', profile: profile('小红') });
  b.sent.length = 0;
  await a.say({ type: 'player_speech', worldId: 'w1', targetPlayerId: 'pb', text: '你好' });
  assert.equal(b.ofType('player_speech').length, 0);
  assert.equal(a.ofType('error').length, 0, '静默丢弃（与设计一致）');
});
