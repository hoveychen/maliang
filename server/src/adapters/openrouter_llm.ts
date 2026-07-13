import type { LLMAdapter } from './types.ts';
import {
  BASE_ABILITIES,
  MEMORY_KINDS,
  type BehaviorScript,
  type CharacterSpec,
  type CreationCategory,
  type CreationState,
  type SessionCompactionContext,
  type ExtractedMemory,
  type GuideCreationResult,
  type IntentContext,
  type IntentResult,
  type MemoryExtractionContext,
  type MemoryKind,
  type ScreenplayDraft,
  type ScreenplayGenContext,
} from '../types.ts';
import { generateScreenplayWithRetry, type GenMessage } from '../screenplay_gen.ts';
import { describeTask } from '../tasks.ts';
import { findOption, optionsByCategory, sizeToScale, inferSizeFromText } from '../creation_options.ts';
import type { CreatureSize } from '../creation_options.ts';
import { findPropOption, propOptionsByCategory, composePropDesc } from '../prop_creation_options.ts';
import { findStickerOption, stickerOptionsByCategory, composeStickerDesc } from '../sticker_creation_options.ts';
import { OpenRouterClient, type ChatMessage } from './openrouter_client.ts';
import { fallbackSdfPropSpec, validateSdfPropSpec, type SdfPropSpec } from '../sdf_prop.ts';
import { isKnownVoice, fallbackVoice, voicePromptLines } from '../voice_catalog.ts';

const DESIGNER_SYSTEM = `你是幼儿园游戏「maliang」的角色设计师。根据小朋友的口头想法，设计一个可爱、儿童友好的角色。
严格只输出 JSON，无 markdown 代码块、无多余文字，格式：
{"name": "中文名字", "personality": "1-2句中文个性描述", "visualDescription": "ENGLISH image prompt", "voiceId": "音色id", "size": "small|medium|big"}
规则：
- name、personality 用中文，温暖童趣。
- size 按小朋友描述的体型判断：明显偏小/迷你→"small"，明显偏大/巨大→"big"，没提或普通→"medium"。它决定角色在世界里的显示高矮。
- visualDescription 用英文，只描述角色主体外观（种类、配色、服饰、表情等），不要写画风/构图/背景——服务端会统一追加画风与绿幕背景。
- **visualDescription 里绝不出现任何角色名、作品名、品牌名**（不写 Pikachu / Pokemon / Elsa / Frozen / Mario / Hello Kitty…），哪怕小朋友就是点名要那个角色。
  改成把这个角色**拆成纯粹的外观特征**来写：体型、配色、五官、标志性部位、服饰。
  例：小朋友说「我要皮卡丘」→ visualDescription 写 "a chubby bright yellow mouse-like creature with long pointed ears tipped in black, red circular cheek patches, brown stripes on its back, and a lightning-bolt-shaped tail"。
  这样小朋友照样拿到她想要的角色，而生图模型不会因为看到名字就拒绝出图（实测：点名 Elsa 会被拒，纯外观描述则 100% 出图）。
  name 和 personality 不受这条限制——小朋友想叫它皮卡丘就叫皮卡丘。
- voiceId 按角色的性格气质与体型从下面的音色表里选，必须原样使用表内 id（方言/台湾腔只给明显匹配的角色，别滥用）：
${voicePromptLines()}
- 绝不包含暴力、恐怖、武器、成人内容。`;

const FALLBACK_VISUAL = 'a cute small round animal friend with a happy smiling face';

// SDF 可动物件设计师：~15 行 JSON 描述一只由基本体融合而成、会动的物件/建筑。
// schema 与客户端 scripts/sdf_spec.gd 对应；产物经 validateSdfPropSpec 校验，坏了走兜底。
const SDF_PROP_SYSTEM = `你是幼儿园游戏「maliang」的物件设计师。小朋友描述一个物件/小建筑（小花、风车、纸、笔、路牌、小房子…），你用若干基本形状拼出它。引擎会把形状无缝融合成一个圆润整体，并按配置生成微动画/旋转件/绳子，需要时才生成腿或翅膀。
严格只输出 JSON，无 markdown、无多余文字。schema：
{"name":"英文snake_case","palette":["#rrggbb",… 2-4个],"blend":0.1~0.35,"outline":0.04,
 "parts":[{"shape":"sphere|capsule|cone|box|torus|bezier","pos":[x,y,z],"color":调色板索引,
   球:"r"; 胶囊:"r","len"; 圆头锥:"r1","r2","h"; 盒:"size":[宽,高,深];
   环/圈/轮子/甜甜圈/把手/光环/方向盘: "shape":"torus","R":大半径,"r":管粗,"arc":弧度(默认180=整圈,90=半圈开口把手);孔默认朝+Z正对镜头,放平成地上呼啦圈/车轮加"rot":[90,0,0];开口(arc<180)默认朝下-Y,用rot转向;
   弯管/花茎/彩带/尾巴/拱门/钩/大象鼻: "shape":"bezier","b":[x,y],"c":[x,y](管从pos出发、经控制点b、弯到终点c,b/c都是相对pos的局部XY平面二维点),"r0":起点粗,"r1":终点粗(可变细),可选"fork":末端开叉口径;
   可选 "rot":[度,度,度]、细小件 "blend":0.05~0.12、会轻轻点头摇摆的部位 "group":"head"、持续旋转件 "spin":{"pivot":[轴心xyz],"axis":[轴向],"rate":每秒圈数0.2~1}}],
 "locomotion":{"type":"none|walker|hopper|flyer","legs":2|4|6,"leg_r":腿粗,"hip_h":髋高,"stance":[左右半距,前后半距],"hop_h":跳高,"rate":频率,"hover_h":悬浮高,"wing_len":翅长,"speed":移速},
 "ropes":[{"pos":[挂点xyz],"segments":3~4,"r":粗,"len":每段长,"color":索引}] 0-2条}
规则：
- **默认是安静的物品**：locomotion 用 "none"（自带轻微呼吸），不要加眼睛/嘴把物品拟人化。只有小朋友明确说"会走/会跳/会飞/活的"才用 walker/hopper/flyer，明确说有脸才加五官。
- 会动的细节优先用轻量手段表达：花头/招牌用 "group":"head"（轻轻摇摆点头）；风车叶/陀螺用 "spin"（多片叶共用同一 pivot/axis 即整体同转）；飘带/穗子用 ropes。
- 圆环状的东西（轮子/光环/呼啦圈/甜甜圈/方向盘/手镯/救生圈）直接用一个 torus，别拿一圈小球硬拼；细长弯曲的东西（花茎/藤蔓/彩带/尾巴/象鼻/拱门/挂钩）用一根 bezier 弯管，别用多段胶囊硬折。这俩能和别的件无缝融合。
- y 向上、单位米，小物件总高 0.1~1.5、建筑 1~3；最大件半径/半边长 ≤0.8；所有件最低点 ≥0（不埋进地面）。身体件 2~6 个就够，引擎融合后自然圆润。
- **按这个物件的正常参考尺寸设计，不要因为小朋友说「大/小」就改变整体尺寸**——体型大小由系统另行整体缩放，你只管把形状本身按常规比例拼好。
- 装饰件（斑点/门/图案）必须凸出宿主表面：其中心放在宿主表面上或更靠外，至少露出一半体积——完全埋进大件内部会被引擎收进皮下、看不见也上不了色。例：宿主是 r=0.8 的球，斑点 r=0.15 的中心离宿主中心应 ≥0.8。
- walker 的 hip_h 与身体底部齐平；hopper/flyer 不长腿。
- 明快温暖的配色；绝不包含暴力、恐怖、武器、成人内容。
示例（弯茎小花，用 bezier 弯茎+torus 花环+球花心，安静物品）：
{"name":"curvy_flower","palette":["#7bc47f","#e07a9c","#f2c14e"],"blend":0.1,"outline":0.04,"parts":[{"shape":"bezier","pos":[0,0,0],"b":[0.08,0.55],"c":[0.28,1.0],"r0":0.06,"r1":0.035,"color":0},{"shape":"torus","pos":[0.28,1.06,0.02],"R":0.22,"r":0.07,"arc":180,"color":1,"group":"head"},{"shape":"sphere","pos":[0.28,1.06,0.04],"r":0.12,"color":2,"group":"head"}],"locomotion":{"type":"none"},"ropes":[]}
示例（小风车，安静物品+旋转叶）：
{"name":"pinwheel","palette":["#e8574b","#f2c14e","#6e4a32"],"blend":0.1,"outline":0.035,"parts":[{"shape":"capsule","pos":[0,0.62,0],"r":0.05,"len":1.05,"color":2,"blend":0.06},{"shape":"cone","pos":[0,1.42,0.1],"r1":0.05,"r2":0.15,"h":0.28,"color":0,"spin":{"pivot":[0,1.2,0.1],"axis":[0,0,1],"rate":0.55}},{"shape":"cone","pos":[0.22,1.2,0.1],"r1":0.05,"r2":0.15,"h":0.28,"rot":[0,0,-90],"color":1,"spin":{"pivot":[0,1.2,0.1],"axis":[0,0,1],"rate":0.55}}],"locomotion":{"type":"none"},"ropes":[]}`;

/** 每个能力喂给意图 LLM 的说明（能力名=一句用途 + params 形状）。 */
const ABILITY_DESC: Record<string, string> = {
  move_to: 'move_to=去某个地方或某个角色身边，params:{"location_name":"地点名"} 或 {"character_name":"角色名"}（小朋友说「过来/到我这来」时 character_name 填"玩家"）',
  follow: 'follow=跟着一个人一起走，params:{"target_name":"玩家"}（跟着小朋友）或 {"target_name":"角色名"}',
  stop_follow: 'stop_follow=停止跟随，params:{}',
  do_action:
    'do_action=做一个动作，params:{"action":"动作名"}。26 种纸片动作——' +
    'wave挥手 jump跳跳 spin转圈 nod点头 flip翻跟头 backflip后空翻 cartwheel侧手翻 twirl芭蕾旋 helicopter直升机旋 ' +
    'paperflip翻面(露纸背) peek侧身隐身(纸片变一条线) lie_down躺平 faceplant扑街 ' +
    'curl_up卷成纸筒 shiver瑟瑟发抖 wiggle扭扭舞 puff挺胸鼓气 bounce弹弹球 squish拍扁自己 stretch长高高 ' +
    'fold对折躲猫猫 bow_fold折纸鞠躬 corner_wink折角卖萌 paper_plane折成纸飞机绕圈 accordion风琴折 crumple_ball揉成纸团。' +
    '按情绪选：开心=jump|twirl|bounce|wiggle，得意炫耀=puff|backflip|paperflip|helicopter|paper_plane，' +
    '害羞害怕=shiver|curl_up|peek|fold，累了沮丧=lie_down|faceplant，道谢道歉=bow_fold，卖萌撒娇=corner_wink，' +
    '逗小朋友笑=squish|stretch|flip|cartwheel|accordion|crumple_ball；' +
    '小朋友点名要某个动作（如「躺平」「折个纸飞机」）就用对应那个',
  chat_with: 'chat_with=走到某个角色身边和它聊天，params:{"character_name":"角色名"}',
  deliver_message: 'deliver_message=给某个角色带一句话，params:{"to":"角色名","message":"要带的话"}',
  give: 'give=小朋友把自己的贴纸送给某个角色（小朋友亲自走过去送），params:{"character_name":"角色名","item":"贴纸id"}',
  create_prop: 'create_prop=变出/造一个物件或小建筑（小花/风车/纸/小房子…），params:{"description":"物件的中文描述，尽量保留小朋友的原话细节"}',
  create_character: 'create_character=按小朋友的想法变出一个新的活伙伴/小动物/小人（小猫/小恐龙/小精灵/小朋友…），params:{"description":"新伙伴的中文描述，尽量保留小朋友的原话细节：长什么样、什么颜色、叫什么名字、什么性格"}',
  create_sticker: 'create_sticker=按小朋友的想法做一张扁平的贴纸/贴画（太阳/花/星星/爱心/彩虹…这类平面小图案，用来贴在地上或角色身上），params:{"description":"贴纸图案的中文描述，尽量保留小朋友的原话细节：什么图案、什么颜色"}',
  play_game: 'play_game=小朋友想玩一个【多人小游戏】（踢球/老鹰抓小鸡/捉迷藏/丢手绢…这类有规则、大家一起动起来的游戏），params:{"game":"游戏的中文口语描述，尽量保留小朋友的原话，如「踢球」「老鹰抓小鸡」"}',
  guide_to: 'guide_to=带小朋友去某个地方，或带他去找某个人（你飞在前面领路，他自己走），params:{"location_name":"地点名"} 或 {"character_name":"角色名"}',
  guide_stop: 'guide_stop=小朋友不想去了/让你别带路了 → 停止领路，params:{}',
};

function stripFences(s: string): string {
  return s.replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
}

/** 记忆注入时按 kind 分组的中文小标题（memoryLine 分组注入）。 */
const MEMORY_KIND_LABEL: Record<MemoryKind, string> = {
  identity: '关于这个小朋友',
  preference: '小朋友的喜好',
  promise: '你们的约定',
  event: '一起经历过的事',
  relation: '你们的关系',
  creation: '你帮小朋友造过的东西',
};

/**
 * 静/动态边界 marker（学 claude-code-fork 的 SYSTEM_PROMPT_DYNAMIC_BOUNDARY）：
 * 之前是跨轮字节稳定的静态内容（角色卡/能力/规则），可命中 prompt cache；
 * 之后是每轮可变的当前情况（花名册/地点/背包/委托/记忆），不参与缓存前缀。
 */
const PROMPT_DYNAMIC_BOUNDARY = '\n\n——以下是「当前情况」，每次可能不同——';

interface RawSpec {
  name?: unknown;
  personality?: unknown;
  visualDescription?: unknown;
  voiceId?: unknown;
  size?: unknown;
}

function str(v: unknown, fallback: string): string {
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : fallback;
}

export class OpenRouterLLMAdapter implements LLMAdapter {
  readonly #client: OpenRouterClient;
  readonly #model: string;
  readonly #screenplayModel: string;

  constructor(client: OpenRouterClient, model: string, screenplayModel: string = model) {
    this.#client = client;
    this.#model = model;
    // 剧本生成用强模型（硬 codegen）；缺省回落对话模型，但工厂会传 config.screenplayModel。
    this.#screenplayModel = screenplayModel;
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
      // LLM 按性格从音色目录选；非法/缺失按名字稳定哈希落主力池（同名同声）
      voiceId: isKnownVoice(str(raw.voiceId, '')) ? str(raw.voiceId, '') : fallbackVoice(str(raw.name, '新朋友')),
      // 体型→高度倍率：优先用 LLM 判定的 size，缺失/非法则从意图文本兜底推断（与 mock 同 sizeToScale）
      scale: sizeToScale(typeof raw.size === 'string' && raw.size.trim() ? raw.size : inferSizeFromText(intentText)),
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
    const size = sizeToScale(inferSizeFromText(intentText));
    if (!checked.ok) return { ...fallbackSdfPropSpec('mystery_hopper'), scale: size };
    // 体型档倍率由 size 统管（LLM 按中性参考尺寸设计，见 SDF_PROP_SYSTEM），覆写 validate 的默认 1.0
    return { ...checked.spec, scale: size };
  }

  async routeIntent(transcript: string, ctx: IntentContext): Promise<IntentResult> {
    // 能力集已由调用方（voice.ts 的 effectiveAbilities）算好：基础集 ∪ 角色自带，仙子再减去走动类。
    // 这里不能再擅自并回 BASE_ABILITIES——那会把仙子刚被摘掉的 move_to/follow 又塞回她的 prompt。
    const abilities = ctx.abilities;
    const abilityLines = abilities.map((a) => `- ${ABILITY_DESC[a] ?? a}`).join('\n');

    // 造角色规则只对有该能力的角色（小仙子）出现，免得普通村民误以为自己能造。
    // 依赖角色能力（稳定），放进 staticSystem 前缀不影响 prompt cache。
    const createLine = abilities.includes('create_character')
      ? `\n- 小朋友想要一个「新的活伙伴」（小动物/小人/小精灵，如「我想要一只小猫」「变个小恐龙陪我」）→ kind=command，behaviorScript 一条 {"type":"create_character","params":{"description":"新伙伴的样子/颜色/名字/性格，尽量保留原话"}}；replyText 用你的口吻应下（如「好呀，我这就变出来！」）。要的是没生命的物件/植物/建筑才用 create_prop，别混。`
      : '';
    // 造贴纸规则：明确「贴纸/贴画」这类扁平小图案走 create_sticker，与造物（立体物件）、造角色（活伙伴）区分开。
    const stickerLine = abilities.includes('create_sticker')
      ? `\n- 小朋友想做「贴纸/贴画」（太阳/花/星星/爱心/彩虹这类扁平的平面小图案，用来贴在地上或角色身上，如「做个太阳贴纸」「我想要一张彩虹贴画」）→ kind=command，behaviorScript 一条 {"type":"create_sticker","params":{"description":"贴纸的图案和颜色，尽量保留原话"}}；replyText 用你的口吻应下（如「好呀，我们来做贴纸！」）。贴纸是扁平图案，立体的物件/建筑用 create_prop，活的伙伴用 create_character，别混。`
      : '';
    // 玩游戏规则：明确「一起玩某个有规则的多人游戏」走 play_game，与造物/造角色/造贴纸区分。
    const playLine = abilities.includes('play_game')
      ? `\n- 小朋友想「玩一个游戏」（踢球/老鹰抓小鸡/捉迷藏/丢手绢这类有规则、大家一起动起来的多人小游戏，如「我们来踢球吧」「玩老鹰抓小鸡」「一起做个游戏」）→ kind=command，behaviorScript 一条 {"type":"play_game","params":{"game":"游戏的口语描述，尽量保留原话，如『踢球』"}}；replyText 用你的口吻应下（如「好呀，我们来玩！」）。这是要开一局游戏，不是造东西——造物/造角色/造贴纸别混进来。`
      : '';
    // 引路规则：只有小仙子有 guide_to。她自己不会走路，「带路」是她飞在前面领、小朋友自己走过去。
    const guideLine = abilities.includes('guide_to')
      ? `\n- 小朋友想「去某个地方」或「去找某个人」（如「带我去风车那儿」「我想找小明」「小明在哪呀」「我们去海边吧」）→ kind=command，behaviorScript 一条 {"type":"guide_to","params":{"location_name":"地点名"}} 或 {"type":"guide_to","params":{"character_name":"角色名"}}；replyText 用你的口吻应下并招呼他跟上（如「好呀，跟我来！」）。地点名/角色名必须用下面「可以带小朋友去的地方和人」里的名字，那里没有的**不要编**——你带不了，就老实说你不知道那在哪儿（kind=chat）。
- 小朋友说「不去了」「不用带了」「我不想去了」→ kind=command，behaviorScript 一条 {"type":"guide_stop","params":{}}；replyText 温柔应下（如「好，那我们不去啦」）。`
      : '';

    // ── 静态前缀（跨轮字节稳定，命中 prompt cache）：角色卡 + 能力 + 贴纸词汇 + 输出格式与规则 ──
    const staticSystem = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。
小朋友对你说了一句话，判断这是「闲聊」还是「让你（或别的角色）做一件会做的事」。
会做的事(abilities)：
${abilityLines}
严格只输出 JSON：{"kind":"chat"|"command","replyText":"中文回应","emotion":"happy|think|wave|sad","performer":"角色名或省略","offerTask":true或省略,"behaviorScript":{"commands":[{"type":"move_to","params":{"location_name":"…"}}],"loop":false}}
- chat 时不要 behaviorScript。
- 小朋友点名让「别的」角色做事时（如对你说「小蓝跳一下」），必须 kind=command，performer:"小蓝"，behaviorScript 填「小蓝要做的那件事」（此例 {"type":"do_action","params":{"action":"jump"}}）——指令绝不能省，也绝不要填 move_to 去找它：你跑过去传话由游戏自动演出，不用写进指令。replyText 仍由你来说，像去传话（如「好，我这就去告诉小蓝！」）；让你自己做就省略 performer。
- 小朋友说「告诉X…」「帮我跟X说…」是带话：用 deliver_message（to=X，message=要带的话），不要用 move_to——光走过去话就丢了。
- follow 的 target_name 是「跟着谁」：小朋友说「跟我来/跟着我」时填"玩家"。${createLine}${stickerLine}${playLine}${guideLine}
- replyText 用简单、温暖、童趣的中文，符合角色个性，并参考你们之前的对话保持连贯。
- replyText 最多两个短句、40 字以内——听的人是幼儿园小朋友，说太长会走神；一次只说一个意思，别列举。
- 绝不包含暴力、恐怖、成人内容。`;

    // ── 动态后缀（每轮可变，不进缓存前缀）：花名册 / 地点 / 委托 / 分组记忆 ──
    const rosterLine = ctx.worldCharacters && ctx.worldCharacters.length > 0
      ? `\n世界里的其他角色：${ctx.worldCharacters.map((c) => c.name).join('、')}。指令里出现角色名时必须用这些名字（口音/识别不准时对应到最像的一个）。`
      : '';
    const locationLine = ctx.locations && ctx.locations.length > 0
      ? `\n世界里的地点：${ctx.locations.join('、')}。move_to 的 location_name 优先归一到这些名字（说「有风车的地方」就填「风车」）。`
      : '';
    // 引路候选（仅小仙子）：带上所在场景名，让她知道「小明在森林」——孩子说「找小明」时不至于当成不存在。
    const guideTargetLine = ctx.guideTargets && ctx.guideTargets.length > 0
      ? `\n可以带小朋友去的地方和人：${ctx.guideTargets.map((t) => `${t.name}(${t.sceneName})`).join('、')}。guide_to 的名字只能从这里选。`
      : '';
    const taskLine = ctx.activeTask
      ? `\n进行中的小任务：${describeTask(ctx.activeTask)}（委托人是${ctx.activeTask.npcName}，完成能盖一个小红花集邮章）。小朋友问起就温柔提醒，不要重复发起新任务。`
      : ctx.taskCandidate
        ? `\n当下没有进行中的任务。时机合适时（小朋友问「有什么要帮忙的」，或聊天里自然接得上），你可以发起这个小委托：${describeTask(ctx.taskCandidate)}，完成能盖一个集邮章、集满三个换一朵小红花。若这句回应里发起了它，输出 "offerTask": true 并用你的口吻把请求说出来；不合适就别硬塞。`
        : '';
    // 记忆按 kind 分组注入（memoryLine 分组注入）
    const mem = ctx.memory ?? [];
    let memoryLine = '';
    if (mem.length > 0) {
      const groups: string[] = [];
      for (const k of MEMORY_KINDS) {
        const texts = mem.filter((m) => m.kind === k).map((m) => m.text);
        if (texts.length > 0) groups.push(`${MEMORY_KIND_LABEL[k]}：${texts.join('；')}`);
      }
      memoryLine = `\n你还记得关于这个小朋友的事：\n${groups.join('\n')}\n回应时自然地体现你记得这些。`;
    }
    // session 超长压缩的摘要（更早轮次已折叠）：随动态后缀注入，角色不忘本段更早聊过的事
    const summaryLine = ctx.sessionSummary
      ? `\n这次见面更早的对话（已压缩成摘要）：${ctx.sessionSummary}`
      : '';
    const system = staticSystem + PROMPT_DYNAMIC_BOUNDARY + rosterLine + locationLine + guideTargetLine + taskLine + memoryLine + summaryLine;

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
      { jsonObject: true, cache: true, sessionId: ctx.cacheKey },
    );
    let raw: {
      kind?: unknown;
      replyText?: unknown;
      emotion?: unknown;
      performer?: unknown;
      offerTask?: unknown;
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
    if (raw.offerTask === true && ctx.taskCandidate) result.offerTask = true;
    return result;
  }

  async guideCreation(state: CreationState, childInput: string): Promise<GuideCreationResult> {
    const a = state.attrs;
    const known = [
      a.kind && `类型=${a.kind}`, a.color && `颜色=${a.color}`, a.size && `大小=${a.size}`,
      a.traits.length > 0 && `特点=${a.traits.join('、')}`, a.personality && `性格=${a.personality}`, a.name && `名字=${a.name}`,
    ].filter(Boolean).join('，') || '（还什么都不知道）';
    // 各类别的候选项（喂给 LLM 选，name 无图标走语音）
    const catLines = (['kind', 'color', 'size', 'trait', 'personality'] as CreationCategory[])
      .map((c) => `${c}: ${optionsByCategory(c).map((o) => `${o.id}(${o.label})`).join(' ')}`).join('\n');
    const recent = state.recentCreations?.length
      ? `\n你最近帮这个小朋友造过：${state.recentCreations.join('；')}。小朋友说「刚才的/上次的」指的就是这些，据此理解他要什么。`
      : '';
    const system = `你是幼儿游戏里温柔的小神仙，正在按小朋友的想法一步步造一个新伙伴。
已知道的属性：${known}。${recent}
你要么再问一个还不知道的属性（一次只问一个，配 2-4 个选项图标），要么信息够了就开始造。
可选的属性类别与图标（选项用 id）：
${catLines}
名字(name)没有图标：想问名字时 category 填 "name"、optionIds 留空，小朋友会用语音说。
判断规则：至少知道 类型 + （颜色或一个特点）就可以造了；小朋友说「就这样/够了」也立刻造。
如果小朋友表示不想造了（「算了」「不要了」「我不想弄这个啦」「不想要小伙伴了」这类反悔的意思），就输出 cancelled=true，
replyText 给一句温柔不失落的话（如「好呀，那我们不造啦」），此时不要追问、也不要造。
严格只输出 JSON：{"replyText":"你要对小朋友说的话(中文,温暖童趣,≤两句,若在问就把问题和选项自然念出来)","done":true或false,"cancelled":true或false,"description":"done时:把所有属性汇成一句给设计师的中文描述","question":"done=false时的问题","category":"done=false时问的类别","optionIds":["done=false时的选项id"],"updatedAttrs":{"kind":"","color":"","size":"","traits":[""],"personality":"","name":""}}
updatedAttrs 只填这轮从小朋友输入里新解析出的属性（没有就省略字段）。绝不包含暴力、恐怖、武器、成人内容。`;
    // 会话完整对话按标准多轮 messages 回放（npc=assistant 的追问，child=user 的回答）：
    // 上下文完整，模型自然不重复已问过的问题，也能按上一问解读自由语音答案（如「毛毛」是名字）。
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        ...state.dialog.map((t) => ({ role: t.role === 'child' ? ('user' as const) : ('assistant' as const), content: t.text })),
        { role: 'user', content: childInput },
      ],
      { jsonObject: true },
    );
    let raw: Record<string, unknown> = {};
    try {
      raw = JSON.parse(stripFences(content)) as Record<string, unknown>;
    } catch {
      raw = {};
    }
    // 反悔优先：小朋友说不造了，直接收摊（不追问、不造、不累积属性）
    if (raw.cancelled === true) {
      return { replyText: str(raw.replyText, '好呀，那我们不造啦！'), done: false, cancelled: true };
    }
    const done = raw.done === true;
    const result: GuideCreationResult = {
      replyText: str(raw.replyText, done ? '好呀，我这就变出来！' : '你想要什么样的小伙伴呀？'),
      done,
    };
    if (done) {
      result.description = str(raw.description, childInput);
    } else {
      const cat = typeof raw.category === 'string' ? raw.category as CreationCategory : 'kind';
      result.category = cat;
      result.question = str(raw.question, result.replyText);
      // 只保留图标库里真实存在、且属于该类别的 id，兜住 LLM 幻觉
      const ids = Array.isArray(raw.optionIds) ? raw.optionIds.map(String) : [];
      result.optionIds = cat === 'name' ? [] : ids.filter((id) => findOption(id)?.category === cat).slice(0, 4);
      if (cat !== 'name' && result.optionIds.length === 0) {
        result.optionIds = optionsByCategory(cat).slice(0, 4).map((o) => o.id); // LLM 没给有效选项 → 兜底取该类前几个
      }
    }
    if (raw.updatedAttrs && typeof raw.updatedAttrs === 'object') {
      const u = raw.updatedAttrs as Record<string, unknown>;
      const upd: GuideCreationResult['updatedAttrs'] = {};
      if (typeof u.kind === 'string' && u.kind) upd.kind = u.kind;
      if (typeof u.color === 'string' && u.color) upd.color = u.color;
      if (typeof u.size === 'string' && u.size) upd.size = u.size;
      if (typeof u.personality === 'string' && u.personality) upd.personality = u.personality;
      if (typeof u.name === 'string' && u.name) upd.name = u.name;
      if (Array.isArray(u.traits)) upd.traits = u.traits.map(String).filter(Boolean);
      if (Object.keys(upd).length > 0) result.updatedAttrs = upd;
    }
    return result;
  }

  async guideProp(state: CreationState, childInput: string): Promise<GuideCreationResult> {
    const a = state.attrs;
    const known = [
      a.kind && `东西=${a.kind}`, a.color && `颜色=${a.color}`, a.size && `大小=${a.size}`,
      a.motion && `会不会动=${a.motion}`,
    ].filter(Boolean).join('，') || '（还什么都不知道）';
    const catLines = (['kind', 'color', 'size', 'motion'] as CreationCategory[])
      .map((c) => `${c}: ${propOptionsByCategory(c).map((o) => `${o.id}(${o.label})`).join(' ')}`).join('\n');
    const recent = state.recentCreations?.length
      ? `\n你最近帮这个小朋友造过：${state.recentCreations.join('；')}。小朋友说「刚才的/上次的」指的就是这些，据此理解他要什么。`
      : '';
    const system = `你是幼儿游戏里温柔的小神仙，正在按小朋友的想法一步步变出一个新物件（小花、风车、小房子、路牌、球、星星…这类没有生命的东西）。
已知道的属性：${known}。${recent}
你要么再问一个还不知道的属性（一次只问一个，配 2-4 个选项图标），要么信息够了就开始变。
可选的属性类别与图标（选项用 id）：
${catLines}
判断规则：至少知道 是什么东西 + （颜色或会不会动 之一）就可以变了；小朋友说「就这样/够了」也立刻变。
如果小朋友表示不想变了（「算了」「不要了」「我不想弄这个啦」这类反悔的意思），就输出 cancelled=true，
replyText 给一句温柔不失落的话（如「好呀，那我们不变啦」），此时不要追问、也不要变。
严格只输出 JSON：{"replyText":"你要对小朋友说的话(中文,温暖童趣,≤两句,若在问就把问题和选项自然念出来)","done":true或false,"cancelled":true或false,"description":"done时:把所有属性汇成一句给设计师的中文描述(如『一个红色小小的风车，会转』)","question":"done=false时的问题","category":"done=false时问的类别","optionIds":["done=false时的选项id"],"updatedAttrs":{"kind":"","color":"","size":"","motion":""}}
updatedAttrs 只填这轮从小朋友输入里新解析出的属性（没有就省略字段）。绝不包含暴力、恐怖、武器、成人内容。`;
    // 会话完整对话按标准多轮 messages 回放（同 guideCreation）：上下文完整，不重复问、答案有归属。
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        ...state.dialog.map((t) => ({ role: t.role === 'child' ? ('user' as const) : ('assistant' as const), content: t.text })),
        { role: 'user', content: childInput },
      ],
      { jsonObject: true },
    );
    let raw: Record<string, unknown> = {};
    try {
      raw = JSON.parse(stripFences(content)) as Record<string, unknown>;
    } catch {
      raw = {};
    }
    if (raw.cancelled === true) {
      return { replyText: str(raw.replyText, '好呀，那我们不变啦！'), done: false, cancelled: true };
    }
    const done = raw.done === true;
    const result: GuideCreationResult = {
      replyText: str(raw.replyText, done ? '好呀，我这就变出来！' : '你想变出什么呀？'),
      done,
    };
    if (done) {
      result.description = str(raw.description, composePropDesc(state.attrs) || childInput);
    } else {
      const cat = typeof raw.category === 'string' ? raw.category as CreationCategory : 'kind';
      result.category = cat;
      result.question = str(raw.question, result.replyText);
      const ids = Array.isArray(raw.optionIds) ? raw.optionIds.map(String) : [];
      result.optionIds = ids.filter((id) => findPropOption(id)?.category === cat).slice(0, 4);
      if (result.optionIds.length === 0) {
        result.optionIds = propOptionsByCategory(cat).slice(0, 4).map((o) => o.id); // 兜底
      }
    }
    if (raw.updatedAttrs && typeof raw.updatedAttrs === 'object') {
      const u = raw.updatedAttrs as Record<string, unknown>;
      const upd: GuideCreationResult['updatedAttrs'] = {};
      if (typeof u.kind === 'string' && u.kind) upd.kind = u.kind;
      if (typeof u.color === 'string' && u.color) upd.color = u.color;
      if (typeof u.size === 'string' && u.size) upd.size = u.size;
      if (typeof u.motion === 'string' && u.motion) upd.motion = u.motion;
      if (Object.keys(upd).length > 0) result.updatedAttrs = upd;
    }
    return result;
  }

  async guideSticker(state: CreationState, childInput: string): Promise<GuideCreationResult> {
    const a = state.attrs;
    const known = [a.kind && `图案=${a.kind}`, a.color && `颜色=${a.color}`].filter(Boolean).join('，') || '（还什么都不知道）';
    const catLines = (['kind', 'color'] as CreationCategory[])
      .map((c) => `${c}: ${stickerOptionsByCategory(c).map((o) => `${o.id}(${o.label})`).join(' ')}`).join('\n');
    const recent = state.recentCreations?.length
      ? `\n你最近帮这个小朋友做过：${state.recentCreations.join('；')}。小朋友说「刚才的/上次的」指的就是这些。`
      : '';
    const system = `你是幼儿游戏里温柔的小神仙，正在按小朋友的想法做一张扁平的贴纸（太阳、花、星星、爱心、彩虹…这类平面小图案，用来贴在地上或角色身上）。
已知道的属性：${known}。${recent}
你要么再问一个还不知道的属性（一次只问一个，配 2-4 个选项图标），要么信息够了就开始做。
可选的属性类别与图标（选项用 id）：
${catLines}
判断规则：知道 什么图案 就可以做了（颜色可选）；小朋友说「就这样/够了」也立刻做。
如果小朋友表示不想做了（「算了」「不要了」这类反悔的意思），就输出 cancelled=true，
replyText 给一句温柔不失落的话（如「好呀，那我们不做啦」），此时不要追问、也不要做。
严格只输出 JSON：{"replyText":"你要对小朋友说的话(中文,温暖童趣,≤两句,若在问就把问题和选项自然念出来)","done":true或false,"cancelled":true或false,"description":"done时:把图案和颜色汇成一句给设计师的中文描述(如『一个红色的太阳贴纸』)","question":"done=false时的问题","category":"done=false时问的类别","optionIds":["done=false时的选项id"],"updatedAttrs":{"kind":"","color":""}}
updatedAttrs 只填这轮从小朋友输入里新解析出的属性（没有就省略字段）。绝不包含暴力、恐怖、武器、成人内容。`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        ...state.dialog.map((t) => ({ role: t.role === 'child' ? ('user' as const) : ('assistant' as const), content: t.text })),
        { role: 'user', content: childInput },
      ],
      { jsonObject: true },
    );
    let raw: Record<string, unknown> = {};
    try {
      raw = JSON.parse(stripFences(content)) as Record<string, unknown>;
    } catch {
      raw = {};
    }
    if (raw.cancelled === true) {
      return { replyText: str(raw.replyText, '好呀，那我们不做啦！'), done: false, cancelled: true };
    }
    const done = raw.done === true;
    const result: GuideCreationResult = {
      replyText: str(raw.replyText, done ? '好呀，我这就做出来！' : '你想做个什么图案的贴纸呀？'),
      done,
    };
    if (done) {
      result.description = str(raw.description, composeStickerDesc(state.attrs) || childInput);
    } else {
      const cat = typeof raw.category === 'string' ? raw.category as CreationCategory : 'kind';
      result.category = cat;
      result.question = str(raw.question, result.replyText);
      const ids = Array.isArray(raw.optionIds) ? raw.optionIds.map(String) : [];
      result.optionIds = ids.filter((id) => findStickerOption(id)?.category === cat).slice(0, 4);
      if (result.optionIds.length === 0) {
        result.optionIds = stickerOptionsByCategory(cat).slice(0, 4).map((o) => o.id); // 兜底
      }
    }
    if (raw.updatedAttrs && typeof raw.updatedAttrs === 'object') {
      const u = raw.updatedAttrs as Record<string, unknown>;
      const upd: GuideCreationResult['updatedAttrs'] = {};
      if (typeof u.kind === 'string' && u.kind) upd.kind = u.kind;
      if (typeof u.color === 'string' && u.color) upd.color = u.color;
      if (Object.keys(upd).length > 0) result.updatedAttrs = upd;
    }
    return result;
  }

  async designSticker(intentText: string): Promise<{ name: string; prompt: string }> {
    const system = `你在幼儿游戏里把小朋友想要的贴纸设计成一张扁平 die-cut 贴纸图案。
输入是贴纸的中文描述，你要给出：贴纸的中文名字 + 一句英文生图提示（扁平卡通图案、无脸无手脚、干净轮廓，除非本就是笑脸）。
严格只输出 JSON：{"name":"贴纸中文名(如『红色太阳贴纸』)","prompt":"英文扁平贴纸生图提示(如 a cute flat sticker of a red sun)"}
绝不包含暴力、恐怖、武器、成人内容。`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: `贴纸描述：「${intentText}」` },
      ],
      { jsonObject: true },
    );
    let raw: Record<string, unknown> = {};
    try {
      raw = JSON.parse(stripFences(content)) as Record<string, unknown>;
    } catch {
      raw = {};
    }
    return {
      name: str(raw.name, '贴纸'),
      prompt: str(raw.prompt, `a cute flat sticker: ${intentText}`),
    };
  }

  async generateScreenplay(ctx: ScreenplayGenContext): Promise<ScreenplayDraft | null> {
    // 硬 codegen：用【强模型】(#screenplayModel，与对话模型分离)。生成→typecheck→带错回喂重生成的
    // 重试环在 generateScreenplayWithRetry 里(与模型无关、可单测)；这里只提供「把对话喂给强模型」的 draftFn。
    // 全部尝试都过不了 typecheck 返回 null——调用方口头兜底、不开演。
    const draftFn = (messages: GenMessage[]): Promise<string> =>
      this.#client.chatText(this.#screenplayModel, messages as ChatMessage[], { jsonObject: true });
    return generateScreenplayWithRetry(draftFn, ctx);
  }

  async extractMemory(ctx: MemoryExtractionContext): Promise<ExtractedMemory[]> {
    if (ctx.turns.length === 0) return [];
    // 静态系统提示（跨会话字节稳定，命中 cache）：角色卡 + 抽取口径 + 分类 + 输出格式。
    // 动态内容（这段对话 + 已知记忆）放 user 消息，不污染缓存前缀。
    const system = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。你刚和小朋友聊了一会儿。
从「这段对话」里挑出「值得你长期记住」的、关于小朋友或你们关系的要点，并给每条分类。
分类 kind（五选一）：
- identity=名字/身份（「小朋友叫朵朵」）
- preference=喜好/讨厌（「小朋友喜欢恐龙」）
- promise=约定/承诺（「答应明天一起搭积木」）
- event=发生过的事（「今天一起去了河边」）
- relation=关系/情感（「把我当成好朋友」）
要求：
- 0~3 条，每条 text 一句简短中文、第三人称；kind 用上面的英文枚举之一。
- 只记新的、重要的；闲聊寒暄不必记；没有值得记的就空数组。
- 不要重复「已知记忆」（附在对话后面）。
严格只输出 JSON 对象：{"memories":[{"text":"小朋友叫朵朵","kind":"identity"}]}，没有就 {"memories":[]}。`;
    const conversation = ctx.turns.map((t) => `小朋友：${t.child}\n你：${t.npc}`).join('\n');
    const known = ctx.existingMemory.length > 0 ? ctx.existingMemory.join('；') : '（暂无）';
    const user = `【这段对话】\n${conversation}\n\n【已知记忆，勿重复】${known}`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: user },
      ],
      { jsonObject: true, cache: true, sessionId: ctx.cacheKey },
    );
    try {
      const raw = JSON.parse(stripFences(content)) as { memories?: unknown };
      if (Array.isArray(raw.memories)) {
        return raw.memories
          .map((m): ExtractedMemory | null => {
            // 兼容旧格式（纯字符串）与新格式（{text,kind}）：坏 kind 归 event，宁可保守不丢内容。
            if (typeof m === 'string' && m.trim()) return { text: m.trim(), kind: 'event' };
            if (m && typeof m === 'object') {
              const text = typeof (m as { text?: unknown }).text === 'string' ? (m as { text: string }).text.trim() : '';
              if (!text) return null;
              const k = (m as { kind?: unknown }).kind;
              const kind: MemoryKind = MEMORY_KINDS.includes(k as MemoryKind) ? (k as MemoryKind) : 'event';
              return { text, kind };
            }
            return null;
          })
          .filter((m): m is ExtractedMemory => m !== null)
          .slice(0, 3);
      }
    } catch {
      // 解析失败：本轮不记忆（宁可漏记，不写脏数据）
    }
    return [];
  }

  async compactSession(ctx: SessionCompactionContext): Promise<string> {
    const system = `你是幼儿游戏角色「${ctx.characterName}」（个性：${ctx.personality}）。这次见面聊得太久，需要把较早的对话压缩成一段摘要，供你继续聊天时回看。
要求：
- 一段简短中文（≤300字），第三人称，按时间顺序保留关键信息：聊过的话题、小朋友说过的重要事、你们的约定、正在进行的事。
- 若有「上次的摘要」，把它的信息并进来，不要丢。
- 只保留事实，不要评价、不要客套。
严格只输出摘要文本本身，不要 JSON、不要前后缀。`;
    const conversation = ctx.turns.map((t) => (t.role === 'child' ? `小朋友：${t.text}` : `你：${t.text}`)).join('\n');
    const prev = ctx.previousSummary ? `【上次的摘要】\n${ctx.previousSummary}\n\n` : '';
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: `${prev}【要压缩的对话】\n${conversation}` },
      ],
    );
    return content.trim();
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

  async classifyCreatureSize(visualDescription: string): Promise<CreatureSize> {
    // 存量回填：从英文外观描述判体型。只输出一个词，解析不出走正则兜底。
    try {
      const content = await this.#client.chatText(this.#model, [
        { role: 'system', content: 'Classify the body size of the described creature/character as exactly one word: small, medium, or big. Reply with only that word, lowercase, no punctuation.' },
        { role: 'user', content: visualDescription },
      ]);
      const w = stripFences(content).trim().toLowerCase();
      if (w.includes('small')) return 'small';
      if (w.includes('big') || w.includes('large')) return 'big';
      if (w.includes('medium')) return 'medium';
    } catch {
      // 落到正则兜底
    }
    return inferSizeFromText(visualDescription);
  }
}
