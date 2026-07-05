import type { ServiceAdapters, AudioBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import type { Character, VoiceResponse } from './types.ts';
import { pickTaskCandidate } from './tasks.ts';

export interface VoiceInput {
  worldId: string;
  characterId: string;
  audio: AudioBlob;
}

const RECENT_TURNS = 6; // 回喂给角色的近期对话轮数（child+npc 各算一条）
const MEMORY_CAP = 40; // 单角色长期记忆条数上限（超出丢最旧）

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
  return respondToTranscript(input.worldId, input.characterId, transcript, adapters, store);
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
  transcript: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  hooks?: TTSStreamHooks,
): Promise<VoiceResponse> {
  const character = store.getCharacter(worldId, characterId);
  if (!character) throw new CharacterNotFoundError(worldId, characterId);

  // 花名册：世界里其他可指挥的角色（不含自己、不含小神仙——她悬浮不走地面寻路）
  const roster = store
    .listCharacters(worldId)
    .filter((c) => c.id !== characterId && !c.isFairy)
    .map((c) => ({ id: c.id, name: c.name }));

  // 委托：进行中的给 LLM 提醒；没有进行中的生成候选让 LLM 挑时机发起（模板池确定性生成）
  const activeTask = store.getActiveTask(worldId) ?? undefined;
  const taskCandidate = activeTask ? undefined : pickTaskCandidate(worldId, characterId, store) ?? undefined;

  const intent = await adapters.llm.routeIntent(transcript, {
    characterName: character.name,
    personality: character.personality,
    abilities: character.abilities,
    recentHistory: character.chatHistory.slice(-RECENT_TURNS), // 这轮之前的近 N 轮
    memory: character.memory,
    worldCharacters: roster,
    locations: store.getLocations(worldId),
    activeTask,
    taskCandidate,
    inventory: store.getInventory(worldId),
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
  };
  if (intent.kind === 'command' && intent.behaviorScript) {
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
  // LLM 在这句回应里发起了委托候选 → 设为进行中，随 character_response 下发给客户端做提示
  if (intent.offerTask && taskCandidate) {
    store.setActiveTask(worldId, taskCandidate);
    response.task = taskCandidate;
  } else if (activeTask) {
    response.task = activeTask; // 已有委托随回应带下去（客户端断线重连后也能补提示）
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
      finishTurn(store, character, transcript, replyText);
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
  finishTurn(store, character, transcript, replyText);
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

/** 回合收尾：更新对话历史并持久化（chatHistory/behaviorScript 变更）。 */
function finishTurn(store: WorldStore, character: Character, transcript: string, replyText: string): void {
  character.chatHistory.push({ role: 'child', text: transcript, ts: 0 });
  character.chatHistory.push({ role: 'npc', text: replyText, ts: 0 });
  // 注意：长期记忆抽取（extractMemory，含一次 LLM 调用）已移出回复关键路径，
  // 由 WS 处理器在回复发出后后台调用 accumulateMemory。
  store.saveCharacter(character);
}

/**
 * 对话后让角色「自己挑出值得长期记住的要点」，去重 + 上限累积到 character.memory 并持久化。
 * 设计为「尽力而为」：由 WS 处理器在回复发出后后台调用（不 await 进回复路径），
 * 失败/超时只影响这次记忆、绝不影响角色回复。
 */
export async function accumulateMemory(
  worldId: string,
  characterId: string,
  transcript: string,
  replyText: string,
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<void> {
  const character = store.getCharacter(worldId, characterId);
  if (!character) return;
  const remembered = await adapters.llm.extractMemory({
    characterName: character.name,
    personality: character.personality,
    transcript,
    replyText,
    existingMemory: character.memory,
  });
  let changed = false;
  for (const item of remembered) {
    const m = item.trim();
    if (m && !character.memory.includes(m)) {
      character.memory.push(m);
      changed = true;
    }
  }
  if (character.memory.length > MEMORY_CAP) {
    character.memory = character.memory.slice(-MEMORY_CAP); // 超出丢最旧
    changed = true;
  }
  if (changed) store.saveCharacter(character);
}
