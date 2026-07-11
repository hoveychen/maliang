import type { ServiceAdapters, ImageBlob, AudioBlob, VideoBlob } from './types.ts';
import { fallbackVoice } from '../voice_catalog.ts';
import {
  BASE_ABILITIES,
  type CharacterSpec,
  type CreationAttrs,
  type CreationCategory,
  type CreationState,
  type ExtractedMemory,
  type GuideCreationResult,
  type IntentContext,
  type IntentResult,
  type MemoryExtractionContext,
  type SessionCompactionContext,
} from '../types.ts';
import { CREATION_OPTIONS, optionsByCategory } from '../creation_options.ts';
import { PROP_CREATION_OPTIONS, PROP_CREATION_ASK, propOptionsByCategory, composePropDesc } from '../prop_creation_options.ts';
import type { SdfPropSpec } from '../sdf_prop.ts';

// 1x1 透明 PNG，作为生图占位。（须是合法 PNG：Godot 客户端会真解码，CRC 错会拒收；
// 旧值 IDAT CRC 损坏，Node 侧从未校验所以一直没暴露）
const PNG_1x1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4AWMAAQAABQABNtCI3QAAAABJRU5ErkJggg==';

function pngStub(): ImageBlob {
  return { bytes: Uint8Array.from(Buffer.from(PNG_1x1, 'base64')), mime: 'image/png' };
}

// ── 引导式造角色 mock 启发式 ────────────────────────────────────────────────
/** 把累积属性汇成给 designCharacter 的中文描述。 */
function composeCreationDesc(a: { kind?: string; color?: string; size?: string; traits: string[]; personality?: string; name?: string }): string {
  const head = `一只${a.color ?? ''}${a.size ?? ''}的${a.kind ?? '小动物'}`;
  const parts = [head];
  if (a.traits.length > 0) parts.push(a.traits.join('、'));
  if (a.personality) parts.push(`性格${a.personality}`);
  if (a.name) parts.push(`叫${a.name}`);
  return parts.join('，');
}
/** 追问每个类别的问法（mock 固定文案；真实由 LLM 按个性生成）。 */
const CREATION_ASK: Record<CreationCategory, string> = {
  kind: '你想要什么样的小伙伴呀？',
  color: '它是什么颜色的呢？',
  size: '要大大的还是小小的？',
  trait: '它有什么特别的本领吗？',
  personality: '它是什么性格的呀？',
  name: '给它起个名字吧，你想叫它什么？',
  motion: '（造角色不问会不会动）', // 占位：motion 是造物专属类别
};

// 引导式创造里小朋友反悔的说法（真实实现由 LLM 判语义；mock 用关键词模拟同一个 cancelled 信号）。
const CANCEL_WORDS = /(取消|算了|不要了|不想要了|不造了|不变了|不做了|不玩了|不想造|别造了)/;
const CANCEL_LINE = '好呀，那我们不造啦，你想玩点别的也行呀！';

const ANIMALS = ['兔', '猫', '狗', '熊', '龙', '鸟', '鱼', '象', '鹿', '羊'];

function pickName(intent: string): string {
  for (const a of ANIMALS) if (intent.includes(a)) return `小${a}`;
  return '新朋友';
}

// 不适宜词（mock 审核用）。真实实现接专业审核服务。
const BAD_WORDS = /(暴力|血腥|恐怖|武器|杀|枪|刀)/;

// 口语里的「去/到/走」当成移动指令（mock 意图路由用）。
const GO_WORDS = /(去|到|走去|过去)/;

function audioStub(): AudioBlob {
  // 极小的占位音频（mock TTS）。真实 TTS 走 MiniMax 或本地 Kokoro。
  return { bytes: Uint8Array.from([0x52, 0x49, 0x46, 0x46]), mime: 'audio/wav' };
}

function videoStub(): VideoBlob {
  // 极小的占位视频（mock idle 动画）。真实由 Seedance 产出 mp4。
  return { bytes: Uint8Array.from([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70]), mime: 'video/mp4' };
}

/** mock 适配器：不调用任何外部服务，跑通整条编排闭环。 */
export function createMockAdapters(): ServiceAdapters {
  return {
    llm: {
      async designCharacter(intentText: string, _byFairy: boolean): Promise<CharacterSpec> {
        const name = pickName(intentText);
        return {
          name,
          personality: `一个友好、好奇的${name}，喜欢和小朋友玩。`,
          visualDescription: `可爱的${name}，圆润、色彩明亮、儿童友好`,
          voiceId: fallbackVoice(name), // 确定性落主力池（同名同声），与真实路径同兜底
          scale: 1.0,
          abilities: [...BASE_ABILITIES],
        };
      },
      async designSdfProp(intentText: string): Promise<SdfPropSpec> {
        // mock：按关键词确定性挑运动方式，结构固定（真实实现由 LLM 自由拼形状）
        const hop = /(跳|蹦|兔)/.test(intentText);
        const fly = /(飞|翅|蝶|鸟)/.test(intentText);
        const locomotion: SdfPropSpec['locomotion'] = fly
          ? { type: 'flyer', hover_h: 1.4, wing_len: 0.4, rate: 3, speed: 1 }
          : hop
            ? { type: 'hopper', hop_h: 0.45, rate: 1.5, speed: 0.9 }
            : { type: 'walker', legs: 4, leg_r: 0.1, hip_h: 0.6, stance: [0.45, 0.4], speed: 0.8 };
        return {
          name: 'mock_prop',
          palette: ['#e8b04b', '#f4ead4'],
          blend: 0.26,
          outline: 0.04,
          parts: [
            { shape: 'box', pos: [0, 0.95, 0], size: [0.9, 0.7, 0.8], color: 1 },
            { shape: 'sphere', pos: [0, 1.5, 0.2], r: 0.22, color: 0, blend: 0.15 },
          ],
          locomotion,
          ropes: [{ pos: [0, 1.2, -0.45], segments: 3, r: 0.06, len: 0.2, color: 0 }],
        };
      },
      async routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult> {
        // 点名让别的角色执行：转写里出现花名册角色名 → performer（真实实现由 LLM 判断语气）
        const named = (ctx.worldCharacters ?? []).find((c) => transcript.includes(c.name));
        const performerName = named?.name;
        // 造角色意图（仅拥有 create_character 能力的角色，如小神仙）：想要一个新的活伙伴。
        // 放在 create_prop 前：生物类关键词优先归造角色，避免「变一只小猫」被当造物。
        if (
          ctx.abilities.includes('create_character')
          && /(想要|变|造|来|给我|做)/.test(transcript)
          && /(一只|新伙伴|新朋友|小猫|小狗|小恐龙|小龙|小鸟|小兔|小熊|小精灵|小伙伴|小动物)/.test(transcript)
        ) {
          return {
            kind: 'command',
            replyText: '好呀，我这就变出来！',
            behaviorScript: {
              commands: [{ type: 'create_character', params: { description: transcript } }],
              loop: false,
            },
            emotion: 'happy',
          };
        }
        // 造物意图（仅拥有 create_prop 能力的角色，如小神仙）：「变/造/做 一个X」
        if (ctx.abilities.includes('create_prop') && /(变出|变一|造一|做一个|做个)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好呀，看我变出来！',
            behaviorScript: {
              commands: [{ type: 'create_prop', params: { description: transcript } }],
              loop: false,
            },
            emotion: 'happy',
          };
        }
        if (/(别跟|不用跟|停下)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好哒，我不跟啦！',
            behaviorScript: { commands: [{ type: 'stop_follow', params: {} }], loop: false },
            emotion: 'happy',
            performerName,
          };
        }
        if (/(跟我来|跟着我|一起走)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好呀，我跟着你！',
            behaviorScript: { commands: [{ type: 'follow', params: { target_name: '玩家' } }], loop: false },
            emotion: 'happy',
            performerName,
          };
        }
        const actionM = /(挥手|跳一?下|转个?圈|点头)/.exec(transcript);
        if (actionM) {
          const action = ({ 挥: 'wave', 跳: 'jump', 转: 'spin', 点: 'nod' } as Record<string, string>)[actionM[1]![0]!] ?? 'wave';
          return {
            kind: 'command',
            replyText: '看我的！',
            behaviorScript: { commands: [{ type: 'do_action', params: { action } }], loop: false },
            emotion: 'wave',
            performerName,
          };
        }
        if (named && /(聊天|说说话|玩)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: `我去找${named.name}聊聊天！`,
            behaviorScript: {
              commands: [{ type: 'chat_with', params: { character_name: named.name } }],
              loop: false,
            },
            emotion: 'happy',
          };
        }
        // 委托发起：有候选且小朋友问「有什么要帮忙的」→ offerTask
        if (ctx.taskCandidate && /(帮忙|任务|做什么|帮你)/.test(transcript)) {
          return {
            kind: 'chat',
            replyText: `帮我个小忙好不好？完成能盖一个小红花集邮章哦！`,
            emotion: 'happy',
            offerTask: true,
          };
        }
        if (GO_WORDS.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好的，我这就去！',
            behaviorScript: {
              commands: [{ type: 'move_to', params: { location_name: transcript } }],
              loop: false,
            },
            emotion: 'wave',
            performerName,
          };
        }
        return { kind: 'chat', replyText: `（mock 回应）你说的是「${transcript}」对吗？`, emotion: 'happy' };
      },
      async guideCreation(state: CreationState, childInput: string): Promise<GuideCreationResult> {
        // 小朋友反悔（真实 LLM 自己判语义，mock 用关键词模拟出同一个 cancelled 信号，保证确定性）
        if (CANCEL_WORDS.test(childInput)) return { replyText: CANCEL_LINE, done: false, cancelled: true };
        // mock：从输入里按图标 label 认属性；name 类别问过后自由文本当名字。凑够 kind+(color|trait) 或超轮即造。
        const attrs = { ...state.attrs, traits: [...state.attrs.traits] };
        const updated: { kind?: string; color?: string; size?: string; traits?: string[]; personality?: string; name?: string } = {};
        const text = childInput.trim();
        const lastAsked = state.askedCategories.at(-1) as CreationCategory | undefined;
        // 名字优先：上一轮问的是名字，且输入不是某个已知图标 label → 当名字
        const isKnownLabel = CREATION_OPTIONS.some((o) => text.includes(o.label));
        if (lastAsked === 'name' && text && !isKnownLabel && !attrs.name) {
          attrs.name = text; updated.name = text;
        } else {
          for (const o of CREATION_OPTIONS) {
            if (!text.includes(o.label)) continue;
            if (o.category === 'kind' && !attrs.kind) { attrs.kind = o.label; updated.kind = o.label; }
            else if (o.category === 'color' && !attrs.color) { attrs.color = o.label; updated.color = o.label; }
            else if (o.category === 'size' && !attrs.size) { attrs.size = o.label; updated.size = o.label; }
            else if (o.category === 'personality' && !attrs.personality) { attrs.personality = o.label; updated.personality = o.label; }
            else if (o.category === 'trait' && !attrs.traits.includes(o.label)) { attrs.traits.push(o.label); updated.traits = [...attrs.traits]; }
          }
        }
        // 提前造：小朋友说「就这样/好了/够了」
        const early = /(就这样|好了|够了|够啦|可以了)/.test(text);
        const enough = !!attrs.kind && (!!attrs.color || attrs.traits.length > 0);
        const forced = state.turnCount >= 5;
        if (early || enough || forced) {
          const desc = composeCreationDesc(attrs);
          return { replyText: `好呀，我这就变出${desc}！`, done: true, description: desc, updatedAttrs: updated };
        }
        // 追问下一个缺失类别（kind→color→trait→name）
        const next: CreationCategory = !attrs.kind ? 'kind' : !attrs.color ? 'color' : attrs.traits.length === 0 ? 'trait' : 'name';
        const optionIds = next === 'name' ? [] : optionsByCategory(next).slice(0, 4).map((o) => o.id);
        return { replyText: CREATION_ASK[next], done: false, question: CREATION_ASK[next], category: next, optionIds, updatedAttrs: updated };
      },
      async guideProp(state: CreationState, childInput: string): Promise<GuideCreationResult> {
        if (CANCEL_WORDS.test(childInput)) return { replyText: CANCEL_LINE, done: false, cancelled: true };
        // 造物 mock：从输入按图标 label 认属性（kind/color/size/motion），凑够 kind + 一项 或超轮即造。
        const attrs = { ...state.attrs, traits: [...state.attrs.traits] };
        const updated: Partial<CreationAttrs> = {};
        const text = childInput.trim();
        for (const o of PROP_CREATION_OPTIONS) {
          if (!text.includes(o.label)) continue;
          if (o.category === 'kind' && !attrs.kind) { attrs.kind = o.label; updated.kind = o.label; }
          else if (o.category === 'color' && !attrs.color) { attrs.color = o.label; updated.color = o.label; }
          else if (o.category === 'size' && !attrs.size) { attrs.size = o.label; updated.size = o.label; }
          else if (o.category === 'motion' && !attrs.motion) { attrs.motion = o.label; updated.motion = o.label; }
        }
        const early = /(就这样|好了|够了|够啦|可以了)/.test(text);
        const enough = !!attrs.kind && (!!attrs.color || !!attrs.motion || !!attrs.size);
        const forced = state.turnCount >= 5;
        if (early || enough || forced) {
          const desc = composePropDesc(attrs);
          return { replyText: `好呀，我这就变出${desc}！`, done: true, description: desc, updatedAttrs: updated };
        }
        // 追问下一个缺失类别（kind→color→motion→size）
        const next: CreationCategory = !attrs.kind ? 'kind' : !attrs.color ? 'color' : !attrs.motion ? 'motion' : 'size';
        const optionIds = propOptionsByCategory(next).slice(0, 4).map((o) => o.id);
        return { replyText: PROP_CREATION_ASK[next], done: false, question: PROP_CREATION_ASK[next], category: next, optionIds, updatedAttrs: updated };
      },
      async extractMemory(ctx: MemoryExtractionContext): Promise<ExtractedMemory[]> {
        // mock：确定性地扫整段会话的每轮「我叫X」「我喜欢X」抽要点并分类，去重后返回（真实接 LLM 自由判断）
        const child = ctx.turns.map((t) => t.child).join('\n');
        const facts: ExtractedMemory[] = [];
        const nameM = /我叫([^\s，。!！?？]{1,8})/.exec(child);
        if (nameM) facts.push({ text: `小朋友叫${nameM[1]}`, kind: 'identity' });
        const likeM = /我喜欢([^\s，。!！?？]{1,12})/.exec(child);
        if (likeM) facts.push({ text: `小朋友喜欢${likeM[1]}`, kind: 'preference' });
        return facts.filter((f) => !ctx.existingMemory.includes(f.text));
      },
      async compactSession(ctx: SessionCompactionContext): Promise<string> {
        // mock：确定性摘要——并入上次摘要 + 报被压缩的轮数与首末句，供测试断言
        const head = ctx.turns[0]?.text ?? '';
        const tail = ctx.turns.at(-1)?.text ?? '';
        const prev = ctx.previousSummary ? `${ctx.previousSummary}；` : '';
        return `${prev}（压缩了${ctx.turns.length}条：从「${head.slice(0, 10)}」到「${tail.slice(0, 10)}」）`;
      },
      async extractProfile(transcript: string): Promise<{ name: string; nickname: string }> {
        // mock：确定性从「我叫X / 我是X」提取；真实接 LLM 自由理解（含称呼、小名）
        const m = /我(?:叫|是)([^\s，。!！?？]{1,8})/.exec(transcript);
        const name = m ? m[1] : '';
        return { name, nickname: name };
      },
      async respond(prompt: string): Promise<string> {
        return `（mock 回应）你说的是「${prompt}」对吗？`;
      },
    },
    asr: {
      async transcribe(_audio: AudioBlob): Promise<string> {
        return '你好呀'; // mock：固定转写；真实走 sherpa-onnx
      },
      openStream() {
        return {
          feed(_chunk: Uint8Array): void { /* mock：忽略分片 */ },
          async finish(): Promise<string> { return '你好呀'; },
        };
      },
    },
    tts: {
      async synthesize(_text: string, _voiceId: string): Promise<AudioBlob> {
        return audioStub();
      },
    },
    image: {
      async generateSprite(_visualDescription: string): Promise<ImageBlob> {
        return pngStub();
      },
      async generateIcon(_visualDescription: string): Promise<ImageBlob> {
        return pngStub();
      },
    },
    cutout: {
      async removeBackground(input: ImageBlob): Promise<ImageBlob> {
        return input; // mock：原样返回
      },
    },
    video: {
      async generateIdleAnimation(_sprite: ImageBlob): Promise<VideoBlob> {
        return videoStub();
      },
    },
    orientation: {
      async detectFacing(_image: ImageBlob) {
        return 'right' as const; // mock：默认合规朝向（测试想验证翻转/重试时自行覆盖）
      },
    },
    moderation: {
      async moderateText(text: string) {
        return BAD_WORDS.test(text)
          ? { allowed: false, reason: '文字含不适宜内容' }
          : { allowed: true };
      },
    },
  };
}
