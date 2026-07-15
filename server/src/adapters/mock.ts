import type { ServiceAdapters, ImageBlob, AudioBlob, VideoBlob, ClipName } from './types.ts';
import { fallbackVoice } from '../voice_catalog.ts';
import {
  BASE_ABILITIES,
  type AvatarAttrs,
  type AvatarCategory,
  type AvatarGuideState,
  type CharacterSpec,
  type CreationAttrs,
  type CreationCategory,
  type CreationState,
  type ExtractedMemory,
  type GuideAvatarResult,
  type GuideBuildResult,
  type GuideCreationResult,
  type IntentContext,
  type IntentResult,
  type MemoryExtractionContext,
  type ScreenplayDraft,
  type ScreenplayGenContext,
  type SessionCompactionContext,
} from '../types.ts';
import { CREATION_OPTIONS, optionsByCategory, sizeToScale, inferSizeFromText } from '../creation_options.ts';
import { AVATAR_ASK, AVATAR_OPTIONS, avatarOptionsByCategory, composeAvatarDesc } from '../avatar_options.ts';
import type { CreatureSize } from '../creation_options.ts';
import { PROP_CREATION_OPTIONS, PROP_CREATION_ASK, propOptionsByCategory, composePropDesc } from '../prop_creation_options.ts';
import { STICKER_CREATION_OPTIONS, STICKER_CREATION_ASK, stickerOptionsByCategory, composeStickerDesc, stickerIconPrompt } from '../sticker_creation_options.ts';
import { findBlueprint, requiredSlots } from '../build_blueprints.ts';
import { partsForSlot } from '../part_library.ts';
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
  recipient: '这个呀，是给谁做的呀？', // A2：recipient 由 promptRecipient 就地组装，不经 guide；此处仅满足 Record 完整性
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

function videoStub(clip: ClipName): VideoBlob {
  // 极小的占位视频（mock 动画段）。真实由 Seedance 产出 mp4。
  // 末字节按段名区分：资产库是内容寻址的，三段字节若相同会塌成同一个 hash，
  // 就测不出「每段的原片都各自入库」了。
  const tag = { idle: 0x69, moving: 0x6d, talking: 0x74 }[clip];
  return {
    bytes: Uint8Array.from([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, tag]),
    mime: 'video/mp4',
  };
}

// mock generateScreenplay 用的两段最小剧本源码（已知对着 stage_sdk.d.ts 过 typecheck；
// screenplay_gen.test.ts 会断言它们通过 checkScreenplay，回归时不会静默变坏）。
// cast 都为空——只用球/区域/玩家，不依赖村民数量，测试确定性最高。
const MOCK_SOCCER_SCREENPLAY = `const center = (stage.params.center as Spot | undefined) ?? { x: 75, y: 75 };
const goal = stage.region((stage.params.goal as { x: number; y: number; r: number } | undefined) ?? { x: 20, y: 75, r: 6 });
const ball = await stage.spawnBall(center);
const board = stage.hud.score('进球');
await stage.narrate('我们来踢球啦！把球踢进门就得分哦，靠近球就能踢！');
const timer = stage.hud.countdown(Number(stage.params.gameSec ?? 60));
await new Promise<void>((resolve) => {
  let over = false;
  timer.onDone(() => { if (!over) { over = true; resolve(); } });
  stage.on('enter', ball, goal, () => {
    if (over) return;
    board.add(1);
    stage.hud.toast('进球啦！');
    void ball.reset(center);
  });
});
timer.cancel();
stage.end({ winner: '大家', praise: '踢得真棒，下次再来玩！' });`;

const MOCK_CHASE_SCREENPLAY = `await stage.narrate('我们来玩个游戏吧！');
if (stage.player) {
  await stage.player.say('我准备好啦！');
}
await stage.sleep(Number(stage.params.gameSec ?? 3));
stage.end({ winner: '大家', praise: '玩得真开心，下次再玩！' });`;

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
          // 体型：从意图文本确定性推断（大→1.4 / 小→0.7 / 其它→1.0），与真实 LLM 路径同 sizeToScale
          scale: sizeToScale(inferSizeFromText(intentText)),
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
        // 环/弯管关键词 → 确定性追加 torus/bezier 部件（真实实现由 LLM 自由拼）
        const ring = /(圈|环|甜甜圈|轮|光环|呼啦圈|镯)/.test(intentText);
        const curvy = /(茎|藤|彩带|尾巴|拱|钩|弯)/.test(intentText);
        const parts: SdfPropSpec['parts'] = [
          { shape: 'box', pos: [0, 0.95, 0], size: [0.9, 0.7, 0.8], color: 1 },
          { shape: 'sphere', pos: [0, 1.5, 0.2], r: 0.22, color: 0, blend: 0.15 },
        ];
        if (ring) parts.push({ shape: 'torus', pos: [0, 1.95, 0.1], R: 0.3, r: 0.08, arc: 180, color: 0, blend: 0.1 });
        if (curvy) parts.push({ shape: 'bezier', pos: [0.4, 0.95, 0], b: [0.2, 0.4], c: [0.5, 0.7], r0: 0.06, r1: 0.03, color: 0, blend: 0.08 });
        return {
          name: 'mock_prop',
          palette: ['#e8b04b', '#f4ead4'],
          blend: 0.26,
          outline: 0.04,
          parts,
          locomotion,
          ropes: [{ pos: [0, 1.2, -0.45], segments: 3, r: 0.06, len: 0.2, color: 0 }],
          // 体型档：从意图文本确定性推断→倍率（与真实路径同 sizeToScale），客户端整体缩放
          scale: sizeToScale(inferSizeFromText(intentText)),
        };
      },
      async routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult> {
        // 点名让别的角色执行：转写里出现花名册角色名 → performer（真实实现由 LLM 判断语气）
        const named = (ctx.worldCharacters ?? []).find((c) => transcript.includes(c.name));
        const performerName = named?.name;
        // 造角色意图（仅拥有 create_character 能力的角色，如点点）：想要一个新的活伙伴。
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
        // 造贴纸意图（仅拥有 create_sticker 能力的角色，如点点）：出现「贴纸/贴画」。
        // 放在 create_prop 前：「做个贴纸」的「做个」也会命中造物，贴纸关键词优先归造贴纸。
        if (ctx.abilities.includes('create_sticker') && /(贴纸|贴画|贴贴)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好呀，我们来做贴纸！',
            behaviorScript: {
              commands: [{ type: 'create_sticker', params: { description: transcript } }],
              loop: false,
            },
            emotion: 'happy',
          };
        }
        // 玩游戏意图（仅拥有 play_game 能力的角色，如点点）：想玩多人小游戏。
        // 放在 create_prop 前：「做个游戏」的「做个」也会命中造物，游戏关键词优先归 play_game。
        if (ctx.abilities.includes('play_game') && /(踢球|玩球|老鹰抓小鸡|捉迷藏|丢手绢|一起玩|玩游戏|做游戏|玩个游戏|做个游戏|来玩)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好呀，我们来玩！',
            behaviorScript: {
              commands: [{ type: 'play_game', params: { game: transcript } }],
              loop: false,
            },
            emotion: 'happy',
          };
        }
        // 停止引路（仅小仙子）：放在 guide_to 前——「不去了」也含「去」，先判否定。
        if (ctx.abilities.includes('guide_stop') && /(不去了|不用带|别带|不想去)/.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好，那我们不去啦。',
            behaviorScript: { commands: [{ type: 'guide_stop', params: {} }], loop: false },
            emotion: 'happy',
          };
        }
        // 引路意图（仅小仙子）：「带我去X」「我想找X」。名字从 guideTargets 里认（LLM 版由 prompt 约束）。
        if (ctx.abilities.includes('guide_to') && /(带我去|带我找|我想去|我要去|我想找|在哪)/.test(transcript)) {
          const hit = (ctx.guideTargets ?? []).find((t) => transcript.includes(t.name));
          if (hit) {
            const params = hit.kind === 'character' ? { character_name: hit.name } : { location_name: hit.name };
            return {
              kind: 'command',
              replyText: '好呀，跟我来！',
              behaviorScript: { commands: [{ type: 'guide_to', params }], loop: false },
              emotion: 'happy',
            };
          }
          // 目标不在候选里：老实说不知道，不硬应下（对齐 prompt 里的「不要编」规则）
          return { kind: 'chat', replyText: '我也不知道那在哪儿呀。', emotion: 'think' };
        }
        // 造物意图（仅拥有 create_prop 能力的角色，如点点）：「变/造/做 一个X」
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
        // 有序匹配：长词在前防"翻跟头/翻面/对折/折角"这类同前缀误吞（26 种动作见 openrouter_llm ABILITY_DESC）
        const ACTION_WORDS: Array<[RegExp, string]> = [
          [/纸飞机/, 'paper_plane'], [/折个?角/, 'corner_wink'], [/对折/, 'fold'],
          [/鞠个?躬/, 'bow_fold'], [/风琴/, 'accordion'], [/揉成?纸?团|揉一?揉/, 'crumple_ball'],
          [/翻个?跟头|前滚翻/, 'flip'], [/后空翻/, 'backflip'], [/侧手翻/, 'cartwheel'],
          [/翻个?面/, 'paperflip'], [/躺平|躺下/, 'lie_down'], [/扑街|摔一?跤/, 'faceplant'],
          [/卷起来|卷成/, 'curl_up'], [/发抖|哆嗦/, 'shiver'], [/扭一?扭/, 'wiggle'],
          [/鼓气|挺胸/, 'puff'], [/弹弹球|弹跳/, 'bounce'], [/拍扁|压扁/, 'squish'],
          [/长高|拉长/, 'stretch'], [/躲起来|藏起来/, 'peek'], [/芭蕾/, 'twirl'],
          [/直升机/, 'helicopter'], [/挥手/, 'wave'], [/跳一?下/, 'jump'],
          [/转个?圈/, 'spin'], [/点头/, 'nod'],
        ];
        const actionHit = ACTION_WORDS.find(([re]) => re.test(transcript));
        if (actionHit) {
          const action = actionHit[1];
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
      async guideSticker(state: CreationState, childInput: string): Promise<GuideCreationResult> {
        if (CANCEL_WORDS.test(childInput)) return { replyText: CANCEL_LINE, done: false, cancelled: true };
        // 造贴纸 mock：从输入按图标 label 认属性（kind 图案/color 颜色），凑够 kind 或超轮即造。
        const attrs = { ...state.attrs, traits: [...state.attrs.traits] };
        const updated: Partial<CreationAttrs> = {};
        const text = childInput.trim();
        for (const o of STICKER_CREATION_OPTIONS) {
          if (!text.includes(o.label)) continue;
          if (o.category === 'kind' && !attrs.kind) { attrs.kind = o.label; updated.kind = o.label; }
          else if (o.category === 'color' && !attrs.color) { attrs.color = o.label; updated.color = o.label; }
        }
        const early = /(就这样|好了|够了|够啦|可以了)/.test(text);
        const enough = !!attrs.kind; // 有图案就能造（颜色可选）
        const forced = state.turnCount >= 5;
        if (early || enough || forced) {
          const desc = composeStickerDesc(attrs);
          return { replyText: `好呀，我这就做出${desc}！`, done: true, description: desc, updatedAttrs: updated };
        }
        // 追问下一个缺失类别（kind→color）
        const next: CreationCategory = !attrs.kind ? 'kind' : 'color';
        const optionIds = stickerOptionsByCategory(next).slice(0, 4).map((o) => o.id);
        return { replyText: STICKER_CREATION_ASK[next], done: false, question: STICKER_CREATION_ASK[next], category: next, optionIds, updatedAttrs: updated };
      },
      async guideAvatar(state: AvatarGuideState, childInput: string): Promise<GuideAvatarResult> {
        // 形象引导 mock：按图标 label 认属性；开放语音（非库内 label）整句收进上一轮问的类别。
        // 凑够 性别+2项外观、说「就这样」、或超轮即 done。无 cancelled——onboarding 必须产出形象。
        const attrs: AvatarAttrs = { ...state.attrs, motifs: [...state.attrs.motifs], extras: [...state.attrs.extras] };
        const updated: Partial<AvatarAttrs> = {};
        const text = childInput.trim();
        const lastAsked = state.askedCategories.at(-1) as AvatarCategory | undefined;
        const isKnownLabel = AVATAR_OPTIONS.some((o) => text.includes(o.label));
        if (lastAsked && text && !isKnownLabel && !/(就这样|好了|够了|够啦|可以了|不想选|不选了)/.test(text)) {
          // 开放语音优先：原话进属性，不归一成库里的词（个性化来源）
          switch (lastAsked) {
            case 'gender': attrs.extras.push(text); updated.extras = [...attrs.extras]; break; // 性别答非所问 → 当外观点收下
            case 'hairstyle': if (!attrs.hairstyle) { attrs.hairstyle = text; updated.hairstyle = text; } break;
            case 'outfit': if (!attrs.outfit) { attrs.outfit = text; updated.outfit = text; } break;
            case 'color': if (!attrs.color) { attrs.color = text; updated.color = text; } break;
            case 'motif': attrs.motifs.push(text); updated.motifs = [...attrs.motifs]; break;
            case 'accessory': if (!attrs.accessory) { attrs.accessory = text; updated.accessory = text; } break;
          }
        } else {
          for (const o of AVATAR_OPTIONS) {
            if (!text.includes(o.label)) continue;
            if (o.category === 'gender' && !attrs.gender) { attrs.gender = o.label; updated.gender = o.label; }
            else if (o.category === 'hairstyle' && !attrs.hairstyle) { attrs.hairstyle = o.label; updated.hairstyle = o.label; }
            else if (o.category === 'outfit' && !attrs.outfit) { attrs.outfit = o.label; updated.outfit = o.label; }
            else if (o.category === 'color' && !attrs.color) { attrs.color = o.label; updated.color = o.label; }
            else if (o.category === 'motif' && !attrs.motifs.includes(o.label)) { attrs.motifs.push(o.label); updated.motifs = [...attrs.motifs]; }
            else if (o.category === 'accessory' && !attrs.accessory) { attrs.accessory = o.label; updated.accessory = o.label; }
          }
        }
        const early = /(就这样|好了|够了|够啦|可以了|不想选|不选了)/.test(text);
        const knownCount = [attrs.hairstyle, attrs.outfit, attrs.color, attrs.accessory].filter(Boolean).length
          + (attrs.motifs.length > 0 ? 1 : 0) + (attrs.extras.length > 0 ? 1 : 0);
        const enough = !!attrs.gender && knownCount >= 2;
        const forced = state.turnCount >= 5;
        if (early || enough || forced) {
          return { replyText: '好嘞，点点这就把你画进魔法世界！', done: true, updatedAttrs: updated };
        }
        // 追问下一个缺失类别（gender→hairstyle→outfit→color→motif→accessory）
        const next: AvatarCategory = !attrs.gender ? 'gender' : !attrs.hairstyle ? 'hairstyle'
          : !attrs.outfit ? 'outfit' : !attrs.color ? 'color' : attrs.motifs.length === 0 ? 'motif' : 'accessory';
        const optionIds = avatarOptionsByCategory(next).slice(0, 4).map((o) => o.id);
        return { replyText: AVATAR_ASK[next], done: false, question: AVATAR_ASK[next], category: next, optionIds, updatedAttrs: updated };
      },
      async describeAvatar(attrs: AvatarAttrs): Promise<string> {
        return composeAvatarDesc(attrs);
      },
      async refineAvatar(description: string, childRequest: string): Promise<string> {
        // 确定性：原描述 + 修改要求（真实 LLM 会把修改融进原文）
        return `${description}。按小朋友的要求调整：${childRequest}`;
      },
      async guideBuild(state: CreationState, childInput: string): Promise<GuideBuildResult> {
        if (CANCEL_WORDS.test(childInput)) return { replyText: CANCEL_LINE, done: false, cancelled: true };
        const build = state.build;
        const bp = build ? findBlueprint(build.blueprintId) : undefined;
        // 蓝图丢了（不该发生）：兜底 done，绝不把孩子卡在半开会话里
        if (!build || !bp) return { replyText: '我们下次再拼好不好？', done: true };
        // 确定性推进：正在问的槽 = 上一轮问过的最后一个槽（advanceBuild 会在本函数返回后把 slotId 记进 askedSlots）。
        const filled = { ...build.filled };
        let filledDelta: { slotId: string; partId: string } | undefined;
        const askedSlot = build.askedSlots.at(-1);
        if (askedSlot && !filled[askedSlot]) {
          const slot = bp.slots.find((s) => s.slotId === askedSlot);
          if (slot) {
            const compatible = partsForSlot(slot.accept);
            // 输入含某兼容零件的中文名（点选路径传的是 name）→ 填它；否则含该零件语义类（category，如「轮子」，
            // 语音路径孩子答功能词）→ 填该类第一个兼容零件；都不含则不填、继续追问同一个槽。
            const match =
              compatible.find((p) => childInput.includes(p.name)) ??
              compatible.find((p) => childInput.includes(p.category));
            if (match) {
              filled[askedSlot] = match.id;
              filledDelta = { slotId: askedSlot, partId: match.id };
            }
          }
        }
        // 早停 / 必填槽全满 / 超轮 → 落成
        const early = /(就这样|好了|够了|够啦|可以了|拼好了|完成了)/.test(childInput);
        const missing = requiredSlots(bp).filter((s) => !filled[s.slotId]);
        const forced = state.turnCount >= 5;
        if (early || missing.length === 0 || forced) {
          return { replyText: `好啦，我们的${bp.name}拼好啦！`, done: true, filled: filledDelta };
        }
        // 追问下一个未填必填槽的 functionHint（只问功能，选项是该槽兼容零件）
        const next = missing[0];
        const optionIds = partsForSlot(next.accept).map((p) => p.id);
        return {
          replyText: `${next.functionHint}？`,
          done: false,
          question: next.functionHint,
          slotId: next.slotId,
          optionIds,
          filled: filledDelta,
        };
      },
      async designSticker(intentText: string): Promise<{ name: string; prompt: string }> {
        // mock：确定性从中文描述里认图案 label → 贴纸名 + 英文扁平贴纸生图 prompt（真实接 LLM 自由理解）
        const kindOpt = STICKER_CREATION_OPTIONS.find((o) => o.category === 'kind' && intentText.includes(o.label));
        const colorOpt = STICKER_CREATION_OPTIONS.find((o) => o.category === 'color' && intentText.includes(o.label));
        const kindLabel = kindOpt?.label ?? '图案';
        const name = `${colorOpt?.label ?? ''}${kindLabel}贴纸`;
        // prompt 走英文图案描述（图案 id → STICKER_ICON_PROMPTS），颜色用英文 id 前缀，喂 generateIcon。
        const kindPrompt = kindOpt ? stickerIconPrompt(kindOpt.id) : 'a cute flat sticker';
        const prompt = colorOpt ? `${colorOpt.id} colored ${kindPrompt}` : kindPrompt;
        return { name, prompt };
      },
      async generateScreenplay(ctx: ScreenplayGenContext): Promise<ScreenplayDraft | null> {
        // mock：按关键词确定性返回一段【已知过 typecheck】的最小剧本（真实实现走强模型 + typecheck 重试环）。
        // 两个变体 cast 都为空（只用球/区域/玩家），buildStageOptsFromDraft 不依赖村民数量，测试稳定。
        const wantsBall = /(球|踢)/.test(ctx.gameDesc);
        const code = wantsBall ? MOCK_SOCCER_SCREENPLAY : MOCK_CHASE_SCREENPLAY;
        return { code, cast: [] };
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
      async classifyCreatureSize(visualDescription: string): Promise<CreatureSize> {
        // mock：确定性走中英正则（真实接 LLM 自由理解英文外观描述）
        return inferSizeFromText(visualDescription);
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
      async generateClip(_sprite: ImageBlob, clip: ClipName): Promise<VideoBlob> {
        return videoStub(clip);
      },
    },
    orientation: {
      async detectFacing(_image: ImageBlob) {
        return 'right' as const; // mock：默认合规朝向（测试想验证翻转/重试时自行覆盖）
      },
    },
    anchors: {
      async detectAnchors(_image: ImageBlob) {
        // mock：确定性点位（头顶正中/两侧中腰），过 nearOpaque 校验与否取决于测试给的图
        return { headTop: { x: 0.5, y: 0.05 }, handL: { x: 0.2, y: 0.55 }, handR: { x: 0.8, y: 0.55 } };
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
