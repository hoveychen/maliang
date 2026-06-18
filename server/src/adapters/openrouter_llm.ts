import type { LLMAdapter } from './types.ts';
import type {
  BehaviorScript,
  CharacterSpec,
  IntentContext,
  IntentResult,
  MemoryExtractionContext,
} from '../types.ts';
import { OpenRouterClient, type ChatMessage } from './openrouter_client.ts';

const DESIGNER_SYSTEM = `你是幼儿园游戏「maliang」的角色设计师。根据小朋友的口头想法，设计一个可爱、儿童友好的角色。
严格只输出 JSON，无 markdown 代码块、无多余文字，格式：
{"name": "中文名字", "personality": "1-2句中文个性描述", "visualDescription": "ENGLISH image prompt"}
规则：
- name、personality 用中文，温暖童趣。
- visualDescription 用英文，描述外观，必须是 Paper-Mario 风格的可爱卡通、色彩明亮、full body、centered、on a pure solid chroma-green #00FF00 background、no shadows。
- 绝不包含暴力、恐怖、武器、成人内容。`;

const FALLBACK_VISUAL =
  'a cute Paper-Mario style cartoon animal, bright colors, full body, centered, on a pure solid chroma-green #00FF00 background, no shadows';

function stripFences(s: string): string {
  return s.replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
}

interface RawSpec {
  name?: unknown;
  personality?: unknown;
  visualDescription?: unknown;
}

function str(v: unknown, fallback: string): string {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : fallback;
}

export class OpenRouterLLMAdapter implements LLMAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;

  constructor(client: OpenRouterClient, model: string) {
    this.#client = client;
    this.#model = model;
  }

  async designCharacter(intentText: string, byFairy: boolean): Promise<CharacterSpec> {
    const who = byFairy ? '小神仙正在按小朋友的想法创造一个新伙伴' : '世界里需要一个新角色';
    const messages: ChatMessage[] = [
      { role: 'system', content: DESIGNER_SYSTEM },
      { role: 'user', content: `${who}。小朋友说：「${intentText}」。请设计这个角色。` },
    ];
    const content = await this.#client.chatText(this.#model, messages, { jsonObject: true });
    let raw: RawSpec = {};
    try {
      raw = JSON.parse(stripFences(content)) as RawSpec;
    } catch {
      raw = {};
    }
    return {
      name: str(raw.name, '新朋友'),
      personality: str(raw.personality, '一个友好、好奇的小伙伴，喜欢和小朋友玩。'),
      visualDescription: str(raw.visualDescription, FALLBACK_VISUAL),
      voiceId: 'cn-child-default', // 真实音色 id 在 M2 接讯飞时确定
      scale: 1.0,
      abilities: ['move_to', 'deliver_message'], // 系统预设能力，固定（不取 LLM 的flavor）
    };
  }

  async routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult> {
    const memoryLine = ctx.memory && ctx.memory.length > 0
      ? `\n你记得关于小朋友的事：${ctx.memory.join('；')}。回应时自然地体现你记得这些。`
      : '';
    const system = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。
小朋友对你说了一句话，判断这是「闲聊」还是「让你做一件你会做的事」。
你会做的事(abilities)：${ctx.abilities.join('、')}（move_to=去某地，deliver_message=给某角色带话）。${memoryLine}
严格只输出 JSON：{"kind":"chat"|"command","replyText":"中文回应","emotion":"happy|think|wave|sad","behaviorScript":{"commands":[{"type":"move_to","params":{"location_name":"…"}}],"loop":false}}
- chat 时不要 behaviorScript。
- replyText 用简单、温暖、童趣的中文，符合角色个性，并参考你们之前的对话保持连贯。
- 绝不包含暴力、恐怖、成人内容。`;
    // 把近 N 轮历史按角色映射成对话消息，让回应有上下文
    const historyMsgs = (ctx.recentHistory ?? []).map((t) => ({
      role: t.role === 'child' ? ('user' as const) : ('assistant' as const),
      content: t.text,
    }));
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        ...historyMsgs,
        { role: 'user', content: transcript },
      ],
      { jsonObject: true },
    );
    let raw: {
      kind?: unknown;
      replyText?: unknown;
      emotion?: unknown;
      behaviorScript?: unknown;
    } = {};
    try {
      raw = JSON.parse(stripFences(content));
    } catch {
      raw = {};
    }
    const kind = raw.kind === 'command' ? 'command' : 'chat';
    const result: IntentResult = {
      kind,
      replyText: str(raw.replyText, '嗯嗯，我在听呢！'),
      emotion: str(raw.emotion, 'happy'),
    };
    if (kind === 'command' && raw.behaviorScript && typeof raw.behaviorScript === 'object') {
      result.behaviorScript = raw.behaviorScript as BehaviorScript;
    }
    return result;
  }

  async extractMemory(ctx: MemoryExtractionContext): Promise<string[]> {
    const known = ctx.existingMemory.length > 0 ? ctx.existingMemory.join('；') : '（暂无）';
    const system = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。你刚和小朋友说了一轮话。
从这轮里挑出「值得你长期记住」的、关于小朋友或你们关系的要点（名字、喜好、约定、发生的事）。
- 0~3 条，每条一句简短中文、第三人称（如「小朋友叫朵朵」「小朋友喜欢恐龙」）。
- 只记新的、重要的；闲聊寒暄不必记；没有值得记的就空数组。
- 不要重复已知记忆：${known}。
严格只输出 JSON 对象：{"memories":["小朋友叫朵朵"]}，没有就 {"memories":[]}。`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: `小朋友说：${ctx.transcript}\n你回应：${ctx.replyText}` },
      ],
      { jsonObject: true },
    );
    try {
      const raw = JSON.parse(stripFences(content)) as { memories?: unknown };
      if (Array.isArray(raw.memories)) {
        return raw.memories
          .filter((m): m is string => typeof m === 'string' && m.trim().length > 0)
          .map((m) => m.trim())
          .slice(0, 3);
      }
    } catch {
      // 解析失败：本轮不记忆（宁可漏记，不写脏数据）
    }
    return [];
  }

  async respond(prompt: string): Promise<string> {
    return this.#client.chatText(this.#model, [
      { role: 'system', content: '你在扮演幼儿游戏里的一个可爱角色，用简单、温暖、童趣的中文回应小朋友。' },
      { role: 'user', content: prompt },
    ]);
  }
}
