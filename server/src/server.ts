import { randomUUID } from 'node:crypto';
import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';
import type { ServiceAdapters, ASRStream } from './adapters/types.ts';
import { createAdapters } from './adapters/factory.ts';
import { loadConfig } from './config.ts';
import { WorldStore } from './persistence.ts';
import { createCharacter, generateSprite, ModerationError } from './orchestrator.ts';
import { triggerIdleAnimation } from './idle_animation.ts';
import { FAIRY_VISUAL_DESC } from './adapters/sprite_style.ts';
import { handleVoice, respondToTranscript, accumulateMemory } from './voice.ts';
import { validateSdfPropSpec } from './sdf_prop.ts';
import { RateLimiter } from './ratelimit.ts';
import { stickerGlyph, type ActiveTask, type Character, type VoiceResponse, type WorldProp } from './types.ts';
import { completeTaskOnEvent, praiseLine, thanksLine } from './tasks.ts';

export interface ServerDeps {
  adapters?: ServiceAdapters;
  store?: WorldStore;
}

/** 在世界中央种一个小神仙（默认能造角色）。 */
function seedFairy(worldId: string): Character {
  return {
    id: randomUUID(),
    worldId,
    isFairy: true,
    name: '小神仙',
    personality: '温柔的小神仙，能按小朋友的想法创造新伙伴。',
    voiceId: 'mock-voice-cn-fairy',
    appearance: { visualDescription: FAIRY_VISUAL_DESC, spriteAsset: '', scale: 1.2 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [{ type: 'wait', params: { duration: 1 } }], loop: true },
    position: { tileX: 500, tileY: 500 },
    abilities: ['move_to', 'deliver_message', 'create_character', 'create_prop'],
    relationships: {},
  };
}

function characterListView(store: WorldStore, worldId: string) {
  return store.listCharacters(worldId);
}

export async function buildServer(deps: ServerDeps = {}): Promise<FastifyInstance> {
  const adapters = deps.adapters ?? createAdapters(loadConfig());
  const store = deps.store ?? new WorldStore(process.env.MALIANG_DATA_DIR ?? './data');
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });
  await app.register(websocket);

  app.get('/health', async () => ({ ok: true, service: 'maliang-server' }));

  // 新建世界（种入小神仙）
  app.post('/worlds', async () => {
    const world = store.createWorld();
    store.addCharacter(seedFairy(world.id));
    return { id: world.id, characters: characterListView(store, world.id) };
  });

  // 拉世界状态。固定的 "default" 世界不存在时自动创建并种入小神仙
  // （初始村民由 seed 脚本生成；客户端默认加载 default 世界）。
  app.get<{ Params: { id: string } }>('/worlds/:id', async (req, reply) => {
    let world = store.getWorld(req.params.id);
    if (!world && req.params.id === 'default') {
      world = store.createWorld('default');
      store.addCharacter(seedFairy('default'));
    }
    if (!world) return reply.code(404).send({ error: 'world not found' });
    return { id: world.id, characters: characterListView(store, world.id), props: store.listProps(world.id) };
  });

  // 为世界里的小神仙补一张真实 sprite。幂等：已有则跳过；?force=true 强制重生成；
  // body 带 pngBase64 时直接存该图（部署验收过的候选，确定性替换，隐含 force）。
  app.post<{
    Params: { id: string };
    Querystring: { force?: string };
    Body: { pngBase64?: string } | null;
  }>('/worlds/:id/fairy-sprite', { bodyLimit: 8 * 1024 * 1024 }, async (req, reply) => {
    const fairy = characterListView(store, req.params.id).find((c) => c.isFairy);
    if (!fairy) return reply.code(404).send({ error: 'no fairy in world' });
    const provided = req.body?.pngBase64;
    const force = req.query.force === 'true' || req.query.force === '1';
    if (fairy.appearance.spriteAsset && !force && !provided) {
      return { id: fairy.id, spriteAsset: fairy.appearance.spriteAsset, regenerated: false };
    }
    const hash = provided
      ? store.putAsset({ bytes: Uint8Array.from(Buffer.from(provided, 'base64')), mime: 'image/png' })
      : await generateSprite(adapters, FAIRY_VISUAL_DESC, store);
    fairy.appearance.spriteAsset = hash;
    fairy.appearance.visualDescription = FAIRY_VISUAL_DESC;
    store.saveCharacter(fairy);
    // 试点：静态立绘先返回，idle 动画后台异步补（客户端轮询 /sprite-anim/:hash）
    triggerIdleAnimation(adapters, store, hash);
    return { id: fairy.id, spriteAsset: hash, regenerated: true };
  });

  // 管理端点：按存量 visualDescription 重生成任意角色立绘（清理旧 prompt 时代
  // 朝向随机的存量素材用，见 tools/regen_old_sprites.mjs）。走完整管线（含朝向兜底）。
  // 生图烧钱且会改小朋友认得的角色形象，必须配 MALIANG_ADMIN_TOKEN 才开放。
  app.post<{ Params: { id: string; cid: string } }>(
    '/worlds/:id/characters/:cid/regen-sprite',
    async (req, reply) => {
      const token = process.env.MALIANG_ADMIN_TOKEN;
      if (!token || req.headers['x-admin-token'] !== token) {
        return reply.code(403).send({ error: 'admin token required' });
      }
      const char = store.getCharacter(req.params.id, req.params.cid);
      if (!char) return reply.code(404).send({ error: 'character not found' });
      const desc = char.appearance.visualDescription.trim();
      if (desc.length === 0) return reply.code(400).send({ error: 'character has no visualDescription' });
      const prev = char.appearance.spriteAsset;
      const hash = await generateSprite(adapters, desc, store);
      char.appearance.spriteAsset = hash;
      store.saveCharacter(char);
      return { id: char.id, name: char.name, prev, spriteAsset: hash };
    },
  );

  // onboarding 玩家形象：描述（由问题答案拼装）→ 生图 → 资产 hash。不建角色——
  // 玩家档案在设备端，资产内容寻址共享。描述过文字审核（防客户端篡改）。
  app.post<{ Body: { visualDescription?: string } | null }>('/player-sprite', async (req, reply) => {
    const desc = (req.body?.visualDescription ?? '').trim();
    if (desc.length === 0) return reply.code(400).send({ error: 'visualDescription required' });
    const check = await adapters.moderation.moderateText(desc);
    if (!check.allowed) return reply.code(400).send({ error: 'moderation blocked' });
    const hash = await generateSprite(adapters, desc, store);
    // 试点：玩家形象静态先返回，idle 动画后台异步补（客户端凭 spriteAsset 轮询 /sprite-anim/:hash）
    triggerIdleAnimation(adapters, store, hash);
    return { spriteAsset: hash };
  });

  // onboarding 自我介绍：转写（客户端直送或送 PCM 走服务端 ASR）→ LLM 提取名字/称呼
  // → TTS 复述确认音频。提取不到名字返回空串，客户端播预制 retry 重问（多轮）。
  app.post<{
    Body: { transcript?: string; pcmBase64?: string; rate?: number } | null;
  }>('/onboarding/intro', { bodyLimit: 8 * 1024 * 1024 }, async (req) => {
    let transcript = (req.body?.transcript ?? '').trim();
    if (transcript.length === 0 && req.body?.pcmBase64) {
      const bytes = Uint8Array.from(Buffer.from(req.body.pcmBase64, 'base64'));
      const mime = `audio/L16;rate=${req.body.rate ?? 16000}`;
      transcript = (await adapters.asr.transcribe({ bytes, mime })).trim();
    }
    if (transcript.length === 0) return { transcript: '', name: '', nickname: '' };
    const prof = await adapters.llm.extractProfile(transcript);
    if (!prof.name && !prof.nickname) return { transcript, name: '', nickname: '' };
    const callName = prof.nickname || prof.name;
    const audio = await adapters.tts.synthesize(`你叫${callName}，对不对呀？`, 'lovely_girl');
    const hash = store.putAsset(audio);
    return {
      transcript,
      name: prof.name,
      nickname: prof.nickname,
      confirmTtsAsset: hash,
      confirmMime: audio.mime,
    };
  });

  // SDF 可动物件：描述 → LLM 设计 spec（~15 行 JSON）→ 服务端校验 → 下发。
  // 客户端 SdfProp.from_spec 再做一次同规则校验（防传输/版本偏差），双保险。
  app.post<{ Body: { description?: string } | null }>('/sdf-props', async (req, reply) => {
    const desc = (req.body?.description ?? '').trim();
    if (desc.length === 0) return reply.code(400).send({ error: 'description required' });
    const check = await adapters.moderation.moderateText(desc);
    if (!check.allowed) return reply.code(400).send({ error: 'moderation blocked' });
    const spec = await adapters.llm.designSdfProp(desc);
    const validated = validateSdfPropSpec(spec);
    if (!validated.ok) return reply.code(502).send({ error: `spec invalid: ${validated.error}` });
    return { spec: validated.spec };
  });

  // 取生成的 sprite 资源
  app.get<{ Params: { hash: string } }>('/assets/:hash', async (req, reply) => {
    const asset = store.getAsset(req.params.hash);
    if (!asset) return reply.code(404).send({ error: 'asset not found' });
    return reply.header('content-type', asset.mime).send(Buffer.from(asset.bytes));
  });

  // 立绘 idle 动画状态轮询：客户端拿到静态 spriteAsset 后轮询本路由，
  // status=ready 时取 animAsset（图集，走 /assets/:hash）+ meta（cols/rows/fps…）切动画。
  // 无记录返回 none（未触发/不在试点范围）；pending 生成中；failed 保留静态。
  app.get<{ Params: { hash: string } }>('/sprite-anim/:hash', async (req) => {
    const rec = store.getSpriteAnim(req.params.hash);
    return rec ?? { status: 'none' };
  });

  // 昂贵操作限流：每连接 N/分钟 + 全局并发上限（防刷付费 API）
  const limiter = new RateLimiter(
    Number(process.env.RATE_PER_MIN ?? 8),
    Number(process.env.RATE_GLOBAL_MAX ?? 4),
  );

  // WebSocket：造角色请求 → 进度推送 → 完成/失败
  app.get('/ws', { websocket: true }, (socket) => {
    const connKey = randomUUID(); // 每连接一个限流 key
    const session = newVoiceSession(); // 边录边传：本连接的语音分片缓冲
    socket.on('message', (raw: Buffer) => {
      void handleWsMessage(socket, raw.toString(), adapters, store, limiter, connKey, session);
    });
    // 连接断开时释放可能仍持有的限流名额（录到一半断线）
    socket.on('close', () => {
      if (session.gate) { session.gate.release(); session.gate = null; }
      session.active = false;
    });
  });

  return app;
}

/** 边说边识别的单连接语音会话：voice_start 开讯飞流，voice_chunk 随到随发，voice_end finish 拿转写走 respondToTranscript。 */
export interface VoiceSession {
  active: boolean;
  worldId: string;
  characterId: string;
  asr: ASRStream | null;
  gate: { release: () => void } | null;
}

export function newVoiceSession(): VoiceSession {
  return { active: false, worldId: '', characterId: '', asr: null, gate: null };
}

/** 得奖语音表扬：委托人音色念表扬词，合成好推 praise_tts（尽力而为，失败不影响主流程）。 */
async function pushPraiseTts(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  task: ActiveTask,
): Promise<void> {
  const npc = store.getCharacter(worldId, task.npcId);
  await pushLineTts(socket, adapters, store, praiseLine(task), npc?.voiceId ?? 'cn-child-default');
}

async function pushLineTts(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  text: string,
  voiceId: string,
): Promise<void> {
  try {
    const audio = await adapters.tts.synthesize(text, voiceId);
    socket.send(JSON.stringify({ type: 'praise_tts', ttsAsset: store.putAsset(audio) }));
  } catch (err) {
    console.warn(`表扬/致谢 TTS 合成失败（不影响主流程）：${String(err)}`);
  }
}

/** create_prop 异步落地：审核 → LLM 设计 spec → 校验 → 持久化 → prop_created 推送（失败推 prop_failed）。 */
export async function createPropAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<void> {
  try {
    const check = await adapters.moderation.moderateText(description);
    if (!check.allowed) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: 'moderation blocked' }));
      return;
    }
    const spec = await adapters.llm.designSdfProp(description);
    const validated = validateSdfPropSpec(spec);
    if (!validated.ok) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: validated.error }));
      return;
    }
    const prop: WorldProp = { id: randomUUID(), spec: validated.spec, tile: null, state: 'placed' };
    store.addProp(worldId, prop);
    socket.send(JSON.stringify({ type: 'prop_created', worldId, prop }));
  } catch (err) {
    socket.send(JSON.stringify({ type: 'prop_failed', reason: String(err) }));
  }
}

export async function handleWsMessage(
  socket: { send: (data: string) => void },
  raw: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  limiter: RateLimiter,
  connKey: string,
  session: VoiceSession,
): Promise<void> {
  let msg: {
    type?: string;
    worldId?: string;
    intentText?: string;
    byFairy?: boolean;
    characterId?: string;
    audio?: string; // base64
    format?: string;
    transcript?: string; // voice_transcript：端侧 ASR 已识别的文本
    locations?: unknown; // world_info：世界地点名清单
    // 奖赏系统：task_event 完成事件 / give_item 转赠
    kind?: string;
    targetName?: string;
    locationName?: string;
    npcId?: string;
    itemId?: string;
    toCharacterId?: string;
    propId?: string; // prop_place：语音生成物件的落位回报
    tileX?: number;
    tileY?: number;
  };
  try {
    msg = JSON.parse(raw);
  } catch {
    socket.send(JSON.stringify({ type: 'error', error: 'invalid json' }));
    return;
  }

  // 客户端上报世界地点名（连上 WS 后一次）：喂给意图 LLM，让「去某地」归一到真实地名。
  // 回 world_state 同步贴纸背包与进行中委托（断线重连/重启后客户端补状态）。
  if (msg.type === 'world_info') {
    const worldId = msg.worldId ?? '';
    const names = (Array.isArray(msg.locations) ? msg.locations : [])
      .filter((n): n is string => typeof n === 'string' && n.trim().length > 0 && n.length <= 20)
      .map((n) => n.trim())
      .slice(0, 32);
    store.setLocations(worldId, names);
    socket.send(JSON.stringify({
      type: 'world_state',
      inventory: store.getInventory(worldId),
      activeTask: store.getActiveTask(worldId),
    }));
    return;
  }

  // 委托完成事件（客户端确定性判定后上报）：匹配进行中委托则发奖+清任务
  if (msg.type === 'task_event') {
    const worldId = msg.worldId ?? '';
    const done = completeTaskOnEvent(worldId, {
      kind: msg.kind ?? '',
      targetName: msg.targetName,
      locationName: msg.locationName,
      npcId: msg.npcId,
      itemId: msg.itemId,
    }, store);
    if (done) {
      socket.send(JSON.stringify({
        type: 'task_complete',
        task: done,
        rewardId: done.rewardId,
        rewardGlyph: stickerGlyph(done.rewardId),
        inventory: store.getInventory(worldId),
      }));
      void pushPraiseTts(socket, adapters, store, worldId, done); // 委托人音色的语音表扬（后台合成，不卡庆祝）
    }
    return; // 不匹配静默忽略（迟到/重复上报无副作用）
  }

  // 转赠贴纸给 NPC：扣背包 + 写进对方长期记忆；若正好是 gift 委托则顺带完成发奖
  if (msg.type === 'give_item') {
    const worldId = msg.worldId ?? '';
    const itemId = msg.itemId ?? '';
    const ok = store.removeSticker(worldId, itemId);
    if (ok) {
      const npc = store.getCharacter(worldId, msg.toCharacterId ?? '');
      if (npc) {
        const line = `小朋友送过我一个${stickerGlyph(itemId)}`;
        if (!npc.memory.includes(line)) {
          npc.memory.push(line);
          store.saveCharacter(npc);
        }
      }
      const done = completeTaskOnEvent(worldId, { kind: 'gift_done', npcId: msg.toCharacterId, itemId }, store);
      if (done) {
        socket.send(JSON.stringify({
          type: 'task_complete',
          task: done,
          rewardId: done.rewardId,
          rewardGlyph: stickerGlyph(done.rewardId),
          inventory: store.getInventory(worldId),
        }));
        void pushPraiseTts(socket, adapters, store, worldId, done); // 委托达成：表扬已含致谢，不再另发
      } else if (npc) {
        void pushLineTts(socket, adapters, store, thanksLine(itemId), npc.voiceId); // 普通转赠：受赠者致谢
      }
    }
    socket.send(JSON.stringify({ type: 'give_result', ok, itemId, inventory: store.getInventory(worldId) }));
    return;
  }

  if (msg.type === 'create_character_request') {
    const requestId = randomUUID();
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'gen_failed', requestId, reason: gate.reason }));
      return;
    }
    const input = {
      worldId: msg.worldId ?? '',
      intentText: msg.intentText ?? '',
      byFairy: msg.byFairy ?? true,
    };
    try {
      const character = await createCharacter(input, adapters, store, (stage) => {
        socket.send(JSON.stringify({ type: 'gen_progress', requestId, stage }));
      });
      socket.send(JSON.stringify({ type: 'gen_complete', requestId, character }));
    } catch (err) {
      const reason = err instanceof ModerationError ? err.message : String(err);
      socket.send(JSON.stringify({ type: 'gen_failed', requestId, reason }));
    } finally {
      gate.release();
    }
    return;
  }

  if (msg.type === 'voice_input') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      const audioBytes = Uint8Array.from(Buffer.from(msg.audio ?? '', 'base64'));
      const response = await handleVoice(
        {
          worldId: msg.worldId ?? '',
          characterId: msg.characterId ?? '',
          audio: { bytes: audioBytes, mime: msg.format ?? 'audio/wav' },
        },
        adapters,
        store,
      );
      socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, msg.worldId ?? '', response.propRequest, adapters, store);
      }
      // 长期记忆后台累积：在回复发出后再做，不阻塞对话；失败/超时只影响这次记忆。
      void accumulateMemory(
        msg.worldId ?? '',
        msg.characterId ?? '',
        response.transcript,
        response.replyText,
        adapters,
        store,
      ).catch(() => {});
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // ── 端侧 ASR：客户端（Android 插件）本地识别完成，直送转写文本，跳过服务端 ASR ──
  if (msg.type === 'voice_transcript') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      const transcript = (msg.transcript ?? '').trim();
      if (!transcript) {
        socket.send(JSON.stringify({ type: 'voice_failed', reason: '转写文本为空' }));
        return;
      }
    // 流式 TTS 钩子：character_response 先行（文字/行为脚本提前到达），音频分片随合成推送。
    const ttsHooks = {
      onResponse: (r: VoiceResponse) => socket.send(JSON.stringify({ type: 'character_response', ...r })),
      onChunk: (pcm: Uint8Array) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
      onEnd: (assetHash: string) => socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: assetHash })),
    };
      const response = await respondToTranscript(
        msg.worldId ?? '',
        msg.characterId ?? '',
        transcript,
        adapters,
        store,
        ttsHooks,
      );
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, msg.worldId ?? '', response.propRequest, adapters, store);
      }
      void accumulateMemory(
        msg.worldId ?? '',
        msg.characterId ?? '',
        response.transcript,
        response.replyText,
        adapters,
        store,
      ).catch(() => {});
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // ── 边说边识别：分片随到随发讯飞，voice_end 时识别已基本完成（见 asr-live-stream 计划）──
  if (msg.type === 'voice_start') {
    if (session.gate) { session.gate.release(); session.gate = null; } // 上一会话没正常收尾，先释放
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    session.active = true;
    session.worldId = msg.worldId ?? '';
    session.characterId = msg.characterId ?? '';
    session.asr = adapters.asr.openStream(); // 立即开讯飞流，分片随到随发
    session.gate = gate;
    return;
  }

  if (msg.type === 'voice_chunk') {
    if (session.active && session.asr && msg.audio) session.asr.feed(Buffer.from(msg.audio, 'base64'));
    return; // 分片实时喂讯飞，不回包
  }

  // 误触/中途放弃（按住说话 <0.4s 松手）：丢弃识别流（finish 让讯飞关 WS/sherpa 释放，
  // 转写弃用），释放 gate，不回任何包——客户端取消后不该看到任何反馈。
  if (msg.type === 'voice_cancel') {
    if (session.asr) void session.asr.finish().catch(() => {});
    session.active = false;
    session.asr = null;
    if (session.gate) { session.gate.release(); session.gate = null; }
    return;
  }

  if (msg.type === 'voice_end') {
    if (!session.active || !session.asr) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: '没有进行中的录音会话' }));
      return;
    }
    const { worldId, characterId, asr } = session;
    session.active = false;
    session.asr = null;
    try {
      const transcript = await asr.finish(); // 识别尾巴：流式期间已基本识完
      const ttsHooks = {
        onResponse: (r: VoiceResponse) => socket.send(JSON.stringify({ type: 'character_response', ...r })),
        onChunk: (pcm: Uint8Array) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
        onEnd: (assetHash: string) => socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: assetHash })),
      };
      const response = await respondToTranscript(worldId, characterId, transcript, adapters, store, ttsHooks);
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, worldId, response.propRequest, adapters, store);
      }
      void accumulateMemory(worldId, characterId, response.transcript, response.replyText, adapters, store).catch(() => {});
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      if (session.gate) { session.gate.release(); session.gate = null; }
    }
    return;
  }

  // 语音生成物件的落位回报：客户端就近找到空位后上报 tile，重载世界按此恢复
  if (msg.type === 'prop_place') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.setPropTile(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not found' }));
    }
    return;
  }

  // 物品摆放/背包（tile 占地校验在客户端 OccupancyMap，服务端只管状态机+持久化）：
  // prop_store 收纳 / prop_take 摆出 / prop_move 挪位。成功无回包（与 prop_place 一致），非法转换回 error。
  if (msg.type === 'prop_store') {
    if (!store.storeProp(msg.worldId ?? '', msg.propId ?? '')) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not placed' }));
    }
    return;
  }
  if (msg.type === 'prop_take') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.takeProp(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not bagged' }));
    }
    return;
  }
  if (msg.type === 'prop_move') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.movePropTile(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not placed' }));
    }
    return;
  }

  socket.send(JSON.stringify({ type: 'error', error: `unknown type: ${msg.type}` }));
}
