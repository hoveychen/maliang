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
  const character = store.getCharacter(input.worldId, input.characterId);
  if (!character) throw new CharacterNotFoundError(input.worldId, input.characterId);

  const transcript = await adapters.asr.transcribe(input.audio);

  const intent = await adapters.llm.routeIntent(transcript, {
    characterName: character.name,
    personality: character.personality,
    abilities: character.abilities,
    recentHistory: character.chatHistory.slice(-RECENT_TURNS), // 这轮之前的近 N 轮
    memory: character.memory,
  });

  // 回应文字落地前过审核；不通过则温和改口。
  const mod = await adapters.moderation.moderateText(intent.replyText);
  const replyText = mod.allowed ? intent.replyText : '我们聊点别的好不好？';

  const tts = await adapters.tts.synthesize(replyText, character.voiceId);
  const ttsAsset = store.putAsset(tts);

  // 更新角色记忆与对话历史（持久化在 store 里的 character 对象上）。
  character.chatHistory.push({ role: 'child', text: transcript, ts: 0 });
  character.chatHistory.push({ role: 'npc', text: replyText, ts: 0 });

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
