import type { LLMAdapter } from './types.ts';
import {
  BASE_ABILITIES,
  type BehaviorScript,
  type CharacterSpec,
  type IntentContext,
  type IntentResult,
  type MemoryExtractionContext,
} from '../types.ts';
import { OpenRouterClient, type ChatMessage } from './openrouter_client.ts';
import { fallbackSdfPropSpec, validateSdfPropSpec, type SdfPropSpec } from '../sdf_prop.ts';

const DESIGNER_SYSTEM = `你是幼儿园游戏「maliang」的角色设计师。根据小朋友的口头想法，设计一个可爱、儿童友好的角色。
严格只输出 JSON，无 markdown 代码块、无多余文字，格式：
{"name": "中文名字", "personality": "1-2句中文个性描述", "visualDescription": "ENGLISH image prompt"}
规则：
- name、personality 用中文，温暖童趣。
- visualDescription 用英文，只描述角色主体外观（种类、配色、服饰、表情等），不要写画风/构图/背景——服务端会统一追加动森（Animal Crossing）画风与绿幕背景。
- 绝不包含暴力、恐怖、武器、成人内容。`;

const FALLBACK_VISUAL = 'a cute small round animal friend with a happy smiling face';

// SDF 可动物件设计师：~15 行 JSON 描述一只由基本体融合而成、会动的物件/建筑。
// schema 与客户端 scripts/sdf_spec.gd 对应；产物经 validateSdfPropSpec 校验，坏了走兜底。
const SDF_PROP_SYSTEM = `你是幼儿园游戏「maliang」的物件设计师。小朋友描述一个会动的物件/小建筑（比如"会走路的小房子""蹦蹦跳跳的邮筒"），你用若干基本形状拼出它。引擎会把形状无缝融合成一个圆润整体，并自动生成腿/翅膀/绳子和动画。
严格只输出 JSON，无 markdown、无多余文字。schema：
{"name":"英文snake_case","palette":["#rrggbb",… 2-4个],"blend":0.2~0.35,"outline":0.04,
 "parts":[{"shape":"sphere|capsule|cone|box","pos":[x,y,z],"color":调色板索引,
   球:"r"; 胶囊:"r","len"; 圆头锥:"r1","r2","h"; 盒:"size":[宽,高,深]; 可选 "rot":[度,度,度]、细小件 "blend":0.05~0.12、头部件 "group":"head"}],
 "locomotion":{"type":"walker|hopper|flyer","legs":2|4|6,"leg_r":腿粗,"hip_h":髋高,"stance":[左右半距,前后半距],"hop_h":跳高,"rate":频率,"hover_h":悬浮高,"wing_len":翅长,"speed":移速},
 "ropes":[{"pos":[挂点xyz],"segments":3~4,"r":粗,"len":每段长,"color":索引}] 0-2条}
规则：
- y 向上、单位米，物件总高 0.8~3；最大件半径/半边长 ≤0.8；所有件最低点 ≥0（不埋进地面）。身体件 2~6 个就够，引擎融合后自然圆润。
- 装饰件（斑点/眼睛/门/嘴）必须凸出宿主表面：其中心放在宿主表面上或更靠外，至少露出一半体积——完全埋进大件内部会被引擎收进皮下、看不见也上不了色。例：宿主是 r=0.8 的球，斑点 r=0.15 的中心离宿主中心应 ≥0.8。
- walker 的 hip_h 与身体底部齐平；hopper/flyer 不长腿。
- ropes 做尾巴/幌子/灯穗等会甩动的部分。
- 明快温暖的配色；绝不包含暴力、恐怖、武器、成人内容。
示例（会走路的小屋）：
{"name":"walking_hut","palette":["#b1543f","#f4ead4","#e8b04b"],"blend":0.3,"outline":0.045,"parts":[{"shape":"box","pos":[0,1.3,0],"size":[1.7,1.2,1.5],"color":1},{"shape":"cone","pos":[0,2.35,0],"r1":1.05,"r2":0.18,"h":0.55,"color":0}],"locomotion":{"type":"walker","legs":4,"leg_r":0.12,"hip_h":0.78,"stance":[0.6,0.5],"speed":0.7},"ropes":[{"pos":[0,2.05,-0.85],"segments":4,"r":0.09,"len":0.26,"color":2}]}`;

/** 每个能力喂给意图 LLM 的说明（能力名=一句用途 + params 形状）。 */
const ABILITY_DESC: Record<string, string> = {
  move_to: 'move_to=去某个地方或某个角色身边，params:{"location_name":"地点名"} 或 {"character_name":"角色名"}（小朋友说「过来/到我这来」时 character_name 填"玩家"）',
  follow: 'follow=跟着一个人一起走，params:{"target_name":"玩家"}（跟着小朋友）或 {"target_name":"角色名"}',
  stop_follow: 'stop_follow=停止跟随，params:{}',
  do_action: 'do_action=做一个动作，params:{"action":"wave|jump|spin|nod"}（挥手/跳/转圈/点头）',
  chat_with: 'chat_with=走到某个角色身边和它聊天，params:{"character_name":"角色名"}',
  deliver_message: 'deliver_message=给某个角色带一句话，params:{"to":"角色名","message":"要带的话"}',
};

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
      abilities: [...BASE_ABILITIES], // 系统预设能力，固定（不取 LLM 的flavor）
    };
  }

  async designSdfProp(intentText: string): Promise<SdfPropSpec> {
    const messages: ChatMessage[] = [
      { role: 'system', content: SDF_PROP_SYSTEM },
      { role: 'user', content: `小朋友说：「${intentText}」。请设计这个会动的物件。` },
    ];
    const content = await this.#client.chatText(this.#model, messages, { jsonObject: true });
    let raw: unknown = null;
    try {
      raw = JSON.parse(stripFences(content));
    } catch {
      raw = null;
    }
    const checked = validateSdfPropSpec(raw);
    if (!checked.ok) return fallbackSdfPropSpec('mystery_hopper');
    return checked.spec;
  }

  async routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult> {
    const memoryLine = ctx.memory && ctx.memory.length > 0
      ? `\n你记得关于小朋友的事：${ctx.memory.join('；')}。回应时自然地体现你记得这些。`
      : '';
    // 能力 = 基础交互集 ∪ 角色自带（存量角色只存了旧两项，取并集免迁移）
    const abilities = [...new Set([...BASE_ABILITIES, ...ctx.abilities])];
    const abilityLines = abilities.map((a) => `- ${ABILITY_DESC[a] ?? a}`).join('\n');
    const rosterLine = ctx.worldCharacters && ctx.worldCharacters.length > 0
      ? `\n世界里的其他角色：${ctx.worldCharacters.map((c) => c.name).join('、')}。指令里出现角色名时必须用这些名字（口音/识别不准时对应到最像的一个）。`
      : '';
    const locationLine = ctx.locations && ctx.locations.length > 0
      ? `\n世界里的地点：${ctx.locations.join('、')}。move_to 的 location_name 优先归一到这些名字（说「有风车的地方」就填「风车」）。`
      : '';
    const system = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。
小朋友对你说了一句话，判断这是「闲聊」还是「让你（或别的角色）做一件会做的事」。
会做的事(abilities)：
${abilityLines}${rosterLine}${locationLine}${memoryLine}
严格只输出 JSON：{"kind":"chat"|"command","replyText":"中文回应","emotion":"happy|think|wave|sad","performer":"角色名或省略","behaviorScript":{"commands":[{"type":"move_to","params":{"location_name":"…"}}],"loop":false}}
- chat 时不要 behaviorScript。
- 小朋友点名让「别的」角色做事时（如对你说「小蓝跟我来」），performer 填那个角色的名字，replyText 仍由你来说，而且你会亲自跑过去把指令带给它，所以回应要像去传话（如「好，我这就去告诉小蓝！」）；让你自己做就省略 performer。
- follow 的 target_name 是「跟着谁」：小朋友说「跟我来/跟着我」时填"玩家"。
- replyText 用简单、温暖、童趣的中文，符合角色个性，并参考你们之前的对话保持连贯。
- replyText 最多两个短句、40 字以内——听的人是幼儿园小朋友，说太长会走神；一次只说一个意思，别列举。
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
      performer?: unknown;
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
      const performer = str(raw.performer, '');
      if (performer && performer !== ctx.characterName) result.performerName = performer;
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

  async extractProfile(transcript: string): Promise<{ name: string; nickname: string }> {
    const system = `一位 3 岁小朋友在游戏里做自我介绍（语音转写，可能有识别噪音）。
提取：name=名字（如「朵朵」「王小明」），nickname=希望被叫的称呼（小名/昵称；没说就用名字）。
提取不到就给空字符串，不要编造。
严格只输出 JSON 对象：{"name":"朵朵","nickname":"朵朵"}。`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: `小朋友说：${transcript}` },
      ],
      { jsonObject: true },
    );
    try {
      const raw = JSON.parse(stripFences(content)) as { name?: unknown; nickname?: unknown };
      const name = typeof raw.name === 'string' ? raw.name.trim() : '';
      const nickname = typeof raw.nickname === 'string' && raw.nickname.trim() ? raw.nickname.trim() : name;
      return { name, nickname };
    } catch {
      return { name: '', nickname: '' }; // 解析失败当没听清，客户端会重问
    }
  }

  async respond(prompt: string): Promise<string> {
    return this.#client.chatText(this.#model, [
      { role: 'system', content: '你在扮演幼儿游戏里的一个可爱角色，用简单、温暖、童趣的中文回应小朋友。' },
      { role: 'user', content: prompt },
    ]);
  }
}
