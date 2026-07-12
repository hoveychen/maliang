import type { ServiceAdapters, AudioBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import type { Character, ChatTurn, VoiceResponse } from './types.ts';
import { effectiveAbilities } from './types.ts';
import { pickTaskCandidate } from './tasks.ts';
import { pickGreeting } from './greetings.ts';

export interface VoiceInput {
  worldId: string;
  characterId: string;
  /** 说话的玩家（设备端稳定 UUID；空串=未上报玩家的历史/旧客户端，记忆落未绑定桶）。 */
  playerId: string;
  audio: AudioBlob;
}

const RECENT_TURNS = 6; // 旧路径兜底：调用方没给 session 历史时，回喂持久 chat_turns 的近 N 条（child+npc 各算一条）

export class CharacterNotFoundError extends Error {
  constructor(worldId: string, characterId: string) {
    super(`character not found: ${worldId}/${characterId}`);
    this.name = 'CharacterNotFoundError';
  }
}

/**
 * 语音输入编排（见 docs/m2-voice-plan.md）：
 * ASR(音频→文字) → 意图路由(闲聊/指令) → 文字审核 → TTS(文字→音频) → 更新 memory/chat_history。
 * 返回 VoiceResponse 供 WS 推 character_response。
 */
export async function handleVoice(
  input: VoiceInput,
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<VoiceResponse> {
  const transcript = await adapters.asr.transcribe(input.audio);
  return respondToTranscript(input.worldId, input.characterId, input.playerId, transcript, adapters, store);
}

/**
 * 流式 TTS 下发钩子（由 WS 处理器实现）：
 * - onResponse：意图/文本就绪即发 character_response（不等音频合成完，文字/情绪/行为脚本提前到达）
 * - onChunk：PCM 分片随合成推 tts_chunk
 * - onEnd：完整音频已存资产，发 tts_end（客户端可忽略，历史回放用）
 */
export interface TTSStreamHooks {
  onResponse(r: VoiceResponse): void;
  onChunk(pcm: Uint8Array): void;
  onEnd(assetHash: string): void;
}

/**
 * ASR 之后的回复编排：意图路由 → TTS → 更新对话历史 → VoiceResponse。
 * 抽出来供「边说边识别」路径复用（转写已由流式会话拿到，无需再 transcribe）。
 * 传入 hooks 且 TTS 支持流式时走流式下发（response 已经 hooks.onResponse 先行送出，
 * 返回值 ttsStreaming=true 告知调用方不要再发一遍）；否则维持原整段 ttsAsset 路径。
 */
export async function respondToTranscript(
  worldId: string,
  characterId: string,
  playerId: string,
  transcript: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  hooks?: TTSStreamHooks,
  clientTts = false,
  sceneId?: string,
  // 当前 session（Visit）里与该角色的上下文（WS 层从 VisitState 取）：完整对话 + 超长压缩摘要。
  // 给了就整段回喂——session 内上下文完整、跨 session 不串（重进世界=新 session，长期记忆走 memories）。
  // 不给（旧 HTTP 路径/直调）退回持久 chat_turns 截尾的老行为。
  sessionCtx?: { history: ChatTurn[]; summary?: string },
): Promise<VoiceResponse> {
  const character = store.getCharacter(worldId, characterId);
  if (!character) throw new CharacterNotFoundError(worldId, characterId);

  // 花名册：当前场景里其他可指挥的角色（不含自己、不含小神仙——她悬浮不走地面寻路）。
  // sceneId 缺省=全世界（老调用点行为不变）；给了则不把别场景的角色列进「小蓝跟我来」的候选。
  const roster = store
    .listCharacters(worldId, sceneId)
    .filter((c) => c.id !== characterId && !c.isFairy)
    .map((c) => ({ id: c.id, name: c.name }));

  // 委托：进行中的给 LLM 提醒；没有进行中的生成候选让 LLM 挑时机发起（模板池确定性生成，按当前场景挑目标）
  const activeTask = store.getActiveTask(worldId, playerId) ?? undefined;
  const taskCandidate = activeTask ? undefined : pickTaskCandidate(worldId, characterId, playerId, store, Math.random, sceneId) ?? undefined;

  // 长期记忆按「当前玩家」维度取该 NPC 对他的记忆（含 aboutPlayer='' 未绑定历史），带 kind 注入（分组）。
  const memories = store.getMemories(characterId, playerId).map((m) => ({ text: m.text, kind: m.kind }));
  const intent = await adapters.llm.routeIntent(transcript, {
    characterName: character.name,
    personality: character.personality,
    // 基础集 ∪ 角色自带；小仙子减去需要走动的能力——她不会走，给了也兑现不了
    abilities: effectiveAbilities(character),
    recentHistory: sessionCtx?.history ?? store.getRecentTurns(characterId, playerId, RECENT_TURNS),
    sessionSummary: sessionCtx?.summary,
    memory: memories,
    worldCharacters: roster,
    locations: store.getLocations(worldId, sceneId),
    activeTask,
    taskCandidate,
    // 稳定缓存键：绑 world×角色×玩家，做 OpenRouter sticky routing 命中 prompt cache（同一对话连续命中）。
    cacheKey: `${worldId}:${characterId}:${playerId}`,
  });

  // 语音回复不再过文字审核（Boss 2026-06-18 决策：多一次 LLM 调用拖慢对话、伤体验）。
  // 回复由 routeIntent 的儿童安全 system prompt 约束生成；造角色路径的 child 自由文本仍走审核。
  const replyText = intent.replyText;

  const response: VoiceResponse = {
    characterId: character.id,
    transcript,
    replyText,
    ttsAsset: '',
    emotion: intent.emotion,
    voiceId: character.voiceId,
  };
  if (intent.kind === 'command' && intent.behaviorScript) {
    // create_prop 不是客户端执行器能力：从脚本里摘走，交给 WS 层异步造物（prop_created 推送）。
    // 摘完若脚本空了就不下发 behaviorScript（这轮只是造物+口头回应）。
    const propCmd = intent.behaviorScript.commands.find((c) => c.type === 'create_prop');
    if (propCmd) {
      const desc = String(propCmd.params?.description ?? '').trim();
      if (desc) response.propRequest = desc;
      intent.behaviorScript.commands = intent.behaviorScript.commands.filter((c) => c.type !== 'create_prop');
    }
    // create_character 同理：不是客户端执行器能力，摘走交给 WS 层异步造角色（gen_complete 推送）。仅小仙子会发。
    const charCmd = intent.behaviorScript.commands.find((c) => c.type === 'create_character');
    if (charCmd) {
      const desc = String(charCmd.params?.description ?? '').trim();
      if (desc) response.characterRequest = desc;
      intent.behaviorScript.commands = intent.behaviorScript.commands.filter((c) => c.type !== 'create_character');
    }
    // create_sticker 同理：摘走交给 WS 层异步造贴纸（sticker_pending/item_created 推送）。仅小仙子会发。
    const stickerCmd = intent.behaviorScript.commands.find((c) => c.type === 'create_sticker');
    if (stickerCmd) {
      const desc = String(stickerCmd.params?.description ?? '').trim();
      if (desc) response.stickerRequest = desc;
      intent.behaviorScript.commands = intent.behaviorScript.commands.filter((c) => c.type !== 'create_sticker');
    }
    if (intent.behaviorScript.commands.length > 0) {
      response.behaviorScript = intent.behaviorScript;
      // 执行者：小朋友点名让别的角色做（「小蓝跟我来」）→ 脚本挂到那个角色；缺省挂正在对话的角色
      const performer = intent.performerName ? findByName(roster, intent.performerName) : undefined;
      if (performer) {
        response.performerId = performer.id;
        const target = store.getCharacter(worldId, performer.id);
        if (target) {
          target.behaviorScript = intent.behaviorScript;
          store.saveCharacter(target);
        }
      } else {
        character.behaviorScript = intent.behaviorScript; // 指令即时生效
      }
    }
  }
  // 造角色/造物/造贴纸入口：不在这里合成/发普通回应，交给 WS 层的引导会话（guideCreation/guideProp/guideSticker）驱动——
  // 由它合成仙子的问句 TTS 并下发 creation_prompt（含图标选项），避免入口这轮重复出声。
  if (response.characterRequest || response.propRequest || response.stickerRequest) return response;
  // LLM 在这句回应里发起了委托候选 → 设为进行中，随 character_response 下发给客户端做提示
  if (intent.offerTask && taskCandidate) {
    store.setActiveTask(worldId, playerId, taskCandidate);
    response.task = taskCandidate;
  } else if (activeTask) {
    response.task = activeTask; // 已有委托随回应带下去（客户端断线重连后也能补提示）
  }

  // clientTts：客户端自己合成（edge-tts），服务端只出文本+voiceId，不落 TTS 资产。
  if (clientTts) {
    finishTurn(store, character, playerId, transcript, replyText);
    return response;
  }

  const streamFn = adapters.tts.synthesizeStream?.bind(adapters.tts);
  if (hooks && streamFn) {
    // 流式：onStart（拿到 mime）即发 character_response，音频分片随合成推送。
    // onStart 之前抛错（如建连失败）会落到 catch 整体回落非流式——response 尚未发出，安全。
    let responded = false;
    try {
      const full = await streamFn(replyText, character.voiceId, {
        onStart: (mime) => {
          response.ttsStreaming = true;
          response.ttsMime = mime;
          responded = true;
          hooks.onResponse(response);
        },
        onChunk: hooks.onChunk,
      });
      hooks.onEnd(store.putAsset(full));
      finishTurn(store, character, playerId, transcript, replyText);
      return response;
    } catch (err) {
      if (responded) throw err; // 已出声，只能向上失败（客户端有 voice_failed/超时兜底）
      console.warn(`流式 TTS 未出声即失败，回落整段路径：${String(err)}`);
      response.ttsStreaming = undefined;
      response.ttsMime = undefined;
    }
  }

  const tts = await adapters.tts.synthesize(replyText, character.voiceId);
  response.ttsAsset = store.putAsset(tts);
  finishTurn(store, character, playerId, transcript, replyText);
  return response;
}

/**
 * 进对话时对方先开口：按角色招呼风格随机选一句招呼词，用该角色自己的 voiceId 走流式 TTS 出声。
 * 与 respondToTranscript 同一 TTS 路径（onStart 发 character_response、onChunk 推分片），但不过 LLM、
 * 不记忆、不算对话轮（招呼不是玩家发起的一轮）。transcript 留空表示这是主动招呼而非对某句的回应。
 * rng 可注入做测试确定性。
 */
export async function greetCharacter(
  worldId: string,
  characterId: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  hooks?: TTSStreamHooks,
  rng: () => number = Math.random,
  clientTts = false,
): Promise<VoiceResponse> {
  const character = store.getCharacter(worldId, characterId);
  if (!character) throw new CharacterNotFoundError(worldId, characterId);

  const line = pickGreeting(character, rng);
  const response: VoiceResponse = {
    characterId: character.id,
    transcript: '', // 主动招呼，无玩家话语
    replyText: line,
    ttsAsset: '',
    emotion: 'wave', // 招呼配挥手情绪（VoiceResponse.emotion 必填）
    greeting: true, // 客户端据此跳过「没听清」提示（招呼不是玩家发起的一轮）
    voiceId: character.voiceId,
  };

  // clientTts：客户端自己合成，服务端只出招呼文本+voiceId。
  if (clientTts) return response;

  const streamFn = adapters.tts.synthesizeStream?.bind(adapters.tts);
  if (hooks && streamFn) {
    let responded = false;
    try {
      const full = await streamFn(line, character.voiceId, {
        onStart: (mime) => {
          response.ttsStreaming = true;
          response.ttsMime = mime;
          responded = true;
          hooks.onResponse(response);
        },
        onChunk: hooks.onChunk,
      });
      hooks.onEnd(store.putAsset(full));
      return response;
    } catch (err) {
      if (responded) throw err;
      console.warn(`招呼流式 TTS 未出声即失败，回落整段路径：${String(err)}`);
      response.ttsStreaming = undefined;
      response.ttsMime = undefined;
    }
  }

  const tts = await adapters.tts.synthesize(line, character.voiceId);
  response.ttsAsset = store.putAsset(tts);
  return response;
}

/** 花名册按名字找角色：先精确，再互相包含（ASR 可能多字/少字，如「小蓝呀」↔「小蓝」）。 */
function findByName(
  roster: { id: string; name: string }[],
  name: string,
): { id: string; name: string } | undefined {
  const n = name.trim();
  if (!n) return undefined;
  return (
    roster.find((c) => c.name === n) ??
    roster.find((c) => c.name.includes(n) || n.includes(c.name))
  );
}

/** 回合收尾：把这轮对话写入 chat_turns（按玩家），并持久化角色状态（behaviorScript 变更）。 */
function finishTurn(
  store: WorldStore,
  character: Character,
  playerId: string,
  transcript: string,
  replyText: string,
): void {
  store.addChatTurn(character.id, playerId, 'child', transcript, 0);
  store.addChatTurn(character.id, playerId, 'npc', replyText, 0);
  // 注意：长期记忆抽取（extractMemory）已移出回复关键路径，改由会话结束（Visit flush）批量做。
  // 这里仍需 saveCharacter：指令即时生效路径可能改了 character.behaviorScript/state。
  store.saveCharacter(character);
}

/**
 * 会话（Visit）结束时，让角色对整段对话增量「自己挑出值得长期记住的要点」，
 * 去重后按 (NPC, 当前玩家) 维度落 memories 表。相比旧「每轮抽一次」，一次会话每个角色只调一次 LLM（省调用）。
 * 设计为「尽力而为」：由 WS 处理器在会话结束（leave_world / socket.close）或超阈值时后台调用，
 * 失败/超时只影响这次记忆、绝不影响角色回复。
 * （记忆条数上限/裁剪留 P5 chat_turns 治理时一并处理，本期先只追加。）
 */
export async function flushMemory(
  worldId: string,
  characterId: string,
  playerId: string,
  turns: { child: string; npc: string }[],
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<void> {
  if (turns.length === 0) return;
  const character = store.getCharacter(worldId, characterId);
  if (!character) return;
  // 已记的（该 NPC 对这个玩家的，含未绑定历史）喂给抽取器去重，并在落地前再兜一次去重。
  const existing = store.getMemories(characterId, playerId);
  const existingTexts = new Set(existing.map((m) => m.text));
  const remembered = await adapters.llm.extractMemory({
    characterName: character.name,
    personality: character.personality,
    turns,
    existingMemory: existing.map((m) => m.text),
    cacheKey: `${worldId}:${characterId}:${playerId}`,
  });
  for (const item of remembered) {
    const text = item.text.trim();
    if (text && !existingTexts.has(text)) {
      existingTexts.add(text);
      store.addMemory(characterId, { text, kind: item.kind, aboutPlayer: playerId, ts: 0 });
    }
  }
}
