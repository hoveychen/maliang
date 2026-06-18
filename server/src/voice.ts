import type { ServiceAdapters, AudioBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import type { VoiceResponse } from './types.ts';

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
 * ASR 之后的回复编排：意图路由 → TTS → 更新对话历史 → VoiceResponse。
 * 抽出来供「边说边识别」路径复用（转写已由流式会话拿到，无需再 transcribe）。
 */
export async function respondToTranscript(
  worldId: string,
  characterId: string,
  transcript: string,
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<VoiceResponse> {
  const character = store.getCharacter(worldId, characterId);
  if (!character) throw new CharacterNotFoundError(worldId, characterId);

  const intent = await adapters.llm.routeIntent(transcript, {
    characterName: character.name,
    personality: character.personality,
    abilities: character.abilities,
    recentHistory: character.chatHistory.slice(-RECENT_TURNS), // 这轮之前的近 N 轮
    memory: character.memory,
  });

  // 语音回复不再过文字审核（Boss 2026-06-18 决策：多一次 LLM 调用拖慢对话、伤体验）。
  // 回复由 routeIntent 的儿童安全 system prompt 约束生成；造角色路径的 child 自由文本仍走审核。
  const replyText = intent.replyText;

  const tts = await adapters.tts.synthesize(replyText, character.voiceId);
  const ttsAsset = store.putAsset(tts);

  // 更新对话历史（持久化在 store 里的 character 对象上）。
  character.chatHistory.push({ role: 'child', text: transcript, ts: 0 });
  character.chatHistory.push({ role: 'npc', text: replyText, ts: 0 });

  // 注意：长期记忆抽取（extractMemory，含一次 LLM 调用）已移出本函数的回复关键路径，
  // 改由 WS 处理器在回复发出后后台调用 accumulateMemory —— 否则记忆调用变慢/卡住会
  // 拖住整条回复，让客户端一直停在「思考中」。

  const response: VoiceResponse = {
    characterId: character.id,
    transcript,
    replyText,
    ttsAsset,
    emotion: intent.emotion,
  };
  if (intent.kind === 'command' && intent.behaviorScript) {
    response.behaviorScript = intent.behaviorScript;
    character.behaviorScript = intent.behaviorScript; // 指令即时生效
  }
  store.saveCharacter(character); // 持久化 chatHistory/behaviorScript 变更
  return response;
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
