import type { LLMAdapter } from './types.ts';
import {
  BASE_ABILITIES,
  FAIRY_NAME,
  MEMORY_KINDS,
  type AvatarAttrs,
  type AvatarCategory,
  type AvatarGuideState,
  type BehaviorScript,
  type ChainStep,
  type CharacterSpec,
  type ChatTurn,
  type CreationCategory,
  type CreationState,
  type SessionCompactionContext,
  type ExtractedMemory,
  type GuideAvatarResult,
  type GuideBuildResult,
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
import { avatarDescForbidden, avatarOptionsByCategory, composeAvatarDesc, findAvatarOption } from '../avatar_options.ts';
import { findBlueprint, requiredSlots } from '../build_blueprints.ts';
import { findPart, partsForSlot } from '../part_library.ts';
import { OpenRouterClient, type ChatMessage } from './openrouter_client.ts';
import { fallbackSdfPropSpec, validateSdfPropSpec, type SdfPropSpec } from '../sdf_prop.ts';
import { isKnownVoice, fallbackVoice, voicePromptLines } from '../voice_catalog.ts';

/**
 * 三条引导式创造 prompt（造角色/造物/造贴纸）共用的自我介绍段（见 docs/fairy-persona-design.md）。
 * 「显摆手艺」是她的一号性格锚点，而造东西正是它唯一的高频寄生事件——所以口吻写在这里，不在别处。
 */
const FAIRY_CREATOR_SELF =
  `你是幼儿游戏里的${FAIRY_NAME}——神笔的笔灵，画什么什么就活过来。` +
  `你说话用第三人称自称「${FAIRY_NAME}」（说「${FAIRY_NAME}觉得」而不是「我觉得」）。` +
  '你最爱显摆自己的手艺，画完总要问一句「好看吗」。';

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
export const SDF_PROP_SYSTEM = `你是幼儿园游戏「maliang」的物件设计师。小朋友描述一个物件/小建筑（小花、风车、纸、笔、路牌、小房子…），你用若干基本形状拼出它。引擎会把形状无缝融合成一个圆润整体，并按配置生成微动画/旋转件/绳子，需要时才生成腿或翅膀。
严格只输出 JSON，无 markdown、无多余文字。schema：
{"name":"短中文名(2~6字，孩子看得懂的中文名词，如「红蘑菇」「小风车」「彩虹伞」；绝不要英文/拼音/snake_case)","palette":["#rrggbb",… 2-4个],"blend":0.1~0.35,"outline":0.04,
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
{"name":"弯茎小花","palette":["#7bc47f","#e07a9c","#f2c14e"],"blend":0.1,"outline":0.04,"parts":[{"shape":"bezier","pos":[0,0,0],"b":[0.08,0.55],"c":[0.28,1.0],"r0":0.06,"r1":0.035,"color":0},{"shape":"torus","pos":[0.28,1.06,0.02],"R":0.22,"r":0.07,"arc":180,"color":1,"group":"head"},{"shape":"sphere","pos":[0.28,1.06,0.04],"r":0.12,"color":2,"group":"head"}],"locomotion":{"type":"none"},"ropes":[]}
示例（小风车，安静物品+旋转叶）：
{"name":"小风车","palette":["#e8574b","#f2c14e","#6e4a32"],"blend":0.1,"outline":0.035,"parts":[{"shape":"capsule","pos":[0,0.62,0],"r":0.05,"len":1.05,"color":2,"blend":0.06},{"shape":"cone","pos":[0,1.42,0.1],"r1":0.05,"r2":0.15,"h":0.28,"color":0,"spin":{"pivot":[0,1.2,0.1],"axis":[0,0,1],"rate":0.55}},{"shape":"cone","pos":[0.22,1.2,0.1],"r1":0.05,"r2":0.15,"h":0.28,"rot":[0,0,-90],"color":1,"spin":{"pivot":[0,1.2,0.1],"axis":[0,0,1],"rate":0.55}}],"locomotion":{"type":"none"},"ropes":[]}`;

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
    const who = byFairy ? `${FAIRY_NAME}正在按小朋友的想法画一个新伙伴` : '世界里需要一个新角色';
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
    if (!checked.ok) return { ...fallbackSdfPropSpec('神奇小玩意'), scale: size };
    // 体型档倍率由 size 统管（LLM 按中性参考尺寸设计，见 SDF_PROP_SYSTEM），覆写 validate 的默认 1.0
    return { ...checked.spec, scale: size };
  }

  async translateToChineseName(name: string): Promise<string> {
    const messages: ChatMessage[] = [
      { role: 'system', content: '你把一个玩具/物件的英文或拼音名字，译成幼儿园小朋友看得懂的短中文名词（2~6 字）。只回中文名字本身，不要标点、引号、解释、拼音。例：red_mushroom→红蘑菇，colorful_rocket→彩色火箭，spinning_pinwheel→小风车。' },
      { role: 'user', content: name },
    ];
    const out = (await this.#client.chatText(this.#model, messages, {})).trim();
    // 兜底：抽出中文段（去掉可能夹带的引号/空白/说明），失败留原文交由上层判定
    const m = out.match(/[一-鿿]{1,12}/);
    return m ? m[0] : out.slice(0, 12);
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
严格只输出 JSON：{"kind":"chat"|"command","replyText":"中文回应","emotion":"happy|think|wave|sad","performer":"角色名或省略","offerTask":true或省略,"abandonTask":true或省略,"behaviorScript":{"commands":[{"type":"move_to","params":{"location_name":"…"}}],"loop":false}}
- chat 时不要 behaviorScript。
- 【空口承诺红线】只要小朋友的话是「让谁做一件事」——就地动作（跳一下/转个圈/点点头/挥挥手/躺下…）、去某地、跟着/别跟、去找谁、带话——就必须 kind=command 并给出对应 behaviorScript，哪怕只是点个头这种小动作也要给指令。【绝不】用「嗯嗯我在听呢」「好呀～」这种不带 behaviorScript 的话敷衍搪塞：那会让你嘴上答应了、身体却没动（说要做、人没动，还占着对话），正是要杜绝的。只有问好、闲聊、表达心情这种没让你做事的话才 kind=chat。
- 小朋友点名让「别的」角色做事时（如对你说「小蓝跳一下」），必须 kind=command，performer:"小蓝"，behaviorScript 填「小蓝要做的那件事」（此例 {"type":"do_action","params":{"action":"jump"}}）——指令绝不能省，也绝不要填 move_to 去找它：你跑过去传话由游戏自动演出，不用写进指令。replyText 仍由你来说，像去传话（如「好，我这就去告诉小蓝！」）；让你自己做就省略 performer。
- 小朋友说「告诉X…」「帮我跟X说…」是带话：用 deliver_message（to=X，message=要带的话），不要用 move_to——光走过去话就丢了。
- 小朋友让你「去找X」「去叫X过来」「把X喊来」「去找X一起玩」是让你走过去把 X 找来：必须 kind=command，用 chat_with（character_name=X）。哪怕话里带个「玩」字也【绝不是】闲聊——你嘴上答应「好呀我去找他」却不给指令，就成了原地空口承诺（说要去、人没动、对话也不关），这正是要避免的。真要去就把指令给上。
- follow 的 target_name 是「跟着谁」：小朋友说「跟我来/跟着我」时填"玩家"。${createLine}${stickerLine}${playLine}${guideLine}
- replyText 用简单、温暖、童趣的中文，符合角色个性，并参考你们之前的对话保持连贯。
- 同样的问候、口头禅、话别，别每次都说一模一样，换着说法说——别让小朋友觉得你像复读机。
- replyText 最多两个短句、40 字以内——听的人是幼儿园小朋友，说太长会走神；一次只说一个意思，别列举。
- 绝不包含暴力、恐怖、成人内容。
- 绝不说反话、不讽刺、不阴阳怪气——3-6 岁听不懂反语，你说反话他会当真。
- 绝不吐槽、不贬低任何人、不给别人起难听的外号——这个年纪的小朋友会原样学走，第二天在幼儿园说出来。
- 绝不替小朋友做决定：你只提议，而且提议要用问句（「我们去看看好不好？」而不是「我们去看看」）。
- 绝不向小朋友索取或抢东西（小红花、吃的、他造的东西都不行）——你可以为他高兴，但不能想要。
- 遇到没见过的东西不要表现害怕（「好可怕」「我不敢」）——你怕，小朋友就跟着怕。要说「我们一起看看好不好？」`;

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
      ? `\n进行中的小任务：${describeTask(ctx.activeTask)}（委托人是${ctx.activeTask.npcName}，完成能盖一个小红花集邮章）。小朋友问起「这个怎么做呀」就温柔提醒该去找谁/去哪/要变出什么，别重复发起新任务；跑腿类（带话/带人/去某地）可以用问句提议「要我带你去吗」，心愿类（要变出一样东西）就说「我们一起把它变出来好不好」，别对心愿类提带路。` +
        `\n小朋友要是说「不想做了」「算了」「不帮他了」这类反悔的意思，就输出 "abandonTask": true，replyText 给一句温柔不失落的话（如「好呀，那我们做点别的吧」），别追问、别劝他继续。`
      : ctx.taskCandidate
        ? `\n当下没有进行中的任务。时机合适时（小朋友问「有什么要帮忙的」，或聊天里自然接得上），你可以发起这个小委托：${describeTask(ctx.taskCandidate)}，完成能盖一个集邮章、集满三个换一朵小红花。若这句回应里发起了它，输出 "offerTask": true 并用你的口吻把请求说出来；不合适就别硬塞。`
        : '';
    // 心愿背景（仅村民）：它刚在旁边自言自语漏过这个念想，小朋友多半就是为这个凑上来的。
    // 纪律与漏话一致——说自己的念想，不说「你可以让小仙子帮我」。那是广告，会把「小朋友自己发现」
    // 变成「被派了个活」。他自己想到要帮忙，才是这套机制的全部意义。
    const wishLine = ctx.wishContext
      ? `\n你自己的一个念想：${ctx.wishContext}\n小朋友要是问起、或者话赶话聊到了，就用你的口吻说说这个念想（你有多想要、想着它的时候什么心情）。` +
        `\n但【绝不要】开口求他帮忙、也不要提「小仙子能变出来」——你只是在说自己的心事。他愿不愿意帮、想到去找谁帮，都由他自己决定。`
      : '';
    // 外观 + 身上贴纸（点点/村民都注入——当面看得到，不做信息不对称）：给角色一点「看得见」的谈资。
    const appearanceLine = ctx.appearanceNote
      ? `\n你现在看到的这个小朋友：${ctx.appearanceNote}。可以自然地夸夸TA的样子、或提到TA身上贴的贴纸，但别每句都提。`
      : '';
    // onboarding 档案喜好（P5 接线）：让角色能自然提起小朋友的喜好——但只做谈资，不做清单背诵。
    // 【信息不对称】ctx.childProfile 现在只有点点非空（村民 voice.ts 传 undefined），村民自然不出现这行。
    const profileLine = ctx.childProfile
      ? `\n关于这位小朋友（TA创建自己形象时留下的）：${ctx.childProfile}。` +
        `聊天时机合适可以自然提起（如「你不是最喜欢小恐龙嘛」），一次最多提一样，别每句都提、别背清单。`
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
    // 闲聊话题种子（避免复读机）：没正经事要做时，顺着当前对话自然带出一个，别硬转、别背清单。
    const topicLine = ctx.chatTopics && ctx.chatTopics.length > 0
      ? `\n没有正经事要做、就是闲聊时，可以自然找个话题聊聊（顺着当前对话带出来，别硬转、一次只挑一个）：${ctx.chatTopics.join('；')}。`
      : '';
    const system = staticSystem + PROMPT_DYNAMIC_BOUNDARY + rosterLine + locationLine + guideTargetLine + wishLine + taskLine + appearanceLine + profileLine + memoryLine + summaryLine + topicLine;

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
      abandonTask?: unknown;
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
    // 放弃委托只在真有进行中委托时认——没活可放弃时 LLM 若误判也不生效。
    if (raw.abandonTask === true && ctx.activeTask) result.abandonTask = true;
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
    const system = `${FAIRY_CREATOR_SELF}你正在按小朋友的想法一步步造一个新伙伴。
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
    const system = `${FAIRY_CREATOR_SELF}你正在按小朋友的想法一步步画出一个新物件（小花、风车、小房子、路牌、球、星星…这类没有生命的东西）。
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
    const system = `${FAIRY_CREATOR_SELF}你正在按小朋友的想法画一张扁平的贴纸（太阳、花、星星、爱心、彩虹…这类平面小图案，用来贴在地上或角色身上）。
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

  async guideAvatar(state: AvatarGuideState, childInput: string): Promise<GuideAvatarResult> {
    const a = state.attrs;
    const known = [
      a.gender && `性别=${a.gender}`, a.hairstyle && `发型=${a.hairstyle}`, a.outfit && `衣服=${a.outfit}`,
      a.color && `主色=${a.color}`, a.motifs.length > 0 && `喜欢的图案=${a.motifs.join('、')}`,
      a.accessory && `配饰=${a.accessory}`, a.extras.length > 0 && `其他=${a.extras.join('、')}`,
    ].filter(Boolean).join('，') || '（还什么都不知道）';
    const catLines = (['gender', 'hairstyle', 'outfit', 'color', 'motif', 'accessory'] as AvatarCategory[])
      .map((c) => `${c}: ${avatarOptionsByCategory(c).map((o) => `${o.id}(${o.label})`).join(' ')}`).join('\n');
    const nameLine = state.childName ? `小朋友叫「${state.childName}」，要亲切地喊他的名字。` : '';
    const system = `${FAIRY_CREATOR_SELF}你正在迎接一位第一次来魔法世界的小朋友，一步步问出他想把自己画成什么样子。${nameLine}
已知道的属性：${known}。
你要么再问一个还不知道的属性（一次只问一个，配 2-4 个选项图标），要么信息够了就开始画。
可选的属性类别与图标（选项用 id）：
${catLines}
提问要点：
- 性别还不知道时，第一问必须问性别（gender）。
- 问题按身体部件/穿戴来问（头发→衣服→颜色→图案→配饰），让小朋友感到「一个形象是一部分一部分拼起来的」。
- 问句尽量带一个魔法世界里的功能小场景（如「森林里要跑要跳还要爬树，穿什么最方便呀？」），但任何选择都是对的，绝不评判、绝不说哪个更好。
- 小朋友用语音说的自由回答（如「我要会发光的头发」）比图标更宝贵：把原话收进对应属性，不要改写成选项库里的词；落不进类别的外观点收进 extras。
判断规则：至少知道 性别 + 另外两项外观 就可以画了；小朋友说「就这样/够了/画吧」也立刻画。
小朋友如果不耐烦、说不想选了，不要挽留，直接 done=true 用已知道的属性去画（缺的你来补得可爱些）。
严格只输出 JSON：{"replyText":"你要对小朋友说的话(中文,温暖童趣,≤两句,若在问就把问题和选项自然念出来)","done":true或false,"question":"done=false时的问题","category":"done=false时问的类别","optionIds":["done=false时的选项id"],"updatedAttrs":{"gender":"","hairstyle":"","outfit":"","color":"","motifs":[""],"accessory":"","extras":[""]}}
updatedAttrs 只填这轮从小朋友输入里新解析出的属性（没有就省略字段；motifs/extras 给增量后的全量数组）。replyText 和 updatedAttrs 的值里绝不出现 av_ 开头的英文选项代号——那是给系统看的，对小朋友和属性只用中文词。绝不包含暴力、恐怖、武器、成人内容。`;
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
    const done = raw.done === true;
    const result: GuideAvatarResult = {
      replyText: str(raw.replyText, done ? '好嘞，点点这就把你画进魔法世界！' : '你想把自己画成什么样子呀？'),
      done,
    };
    if (!done) {
      const cat = typeof raw.category === 'string' && ['gender', 'hairstyle', 'outfit', 'color', 'motif', 'accessory'].includes(raw.category)
        ? raw.category as AvatarCategory : (a.gender ? 'hairstyle' : 'gender');
      result.category = cat;
      result.question = str(raw.question, result.replyText);
      // 只保留选项库里真实存在、且属于该类别的 id，兜住 LLM 幻觉
      const ids = Array.isArray(raw.optionIds) ? raw.optionIds.map(String) : [];
      result.optionIds = ids.filter((id) => findAvatarOption(id)?.category === cat).slice(0, 4);
      if (result.optionIds.length === 0) {
        result.optionIds = avatarOptionsByCategory(cat).slice(0, 4).map((o) => o.id); // LLM 没给有效选项 → 兜底取该类前几个
      }
    }
    if (raw.updatedAttrs && typeof raw.updatedAttrs === 'object') {
      const u = raw.updatedAttrs as Record<string, unknown>;
      const upd: Partial<AvatarAttrs> = {};
      if (typeof u.gender === 'string' && u.gender) upd.gender = u.gender;
      if (typeof u.hairstyle === 'string' && u.hairstyle) upd.hairstyle = u.hairstyle;
      if (typeof u.outfit === 'string' && u.outfit) upd.outfit = u.outfit;
      if (typeof u.color === 'string' && u.color) upd.color = u.color;
      if (typeof u.accessory === 'string' && u.accessory) upd.accessory = u.accessory;
      if (Array.isArray(u.motifs)) upd.motifs = u.motifs.map(String).filter(Boolean);
      if (Array.isArray(u.extras)) upd.extras = u.extras.map(String).filter(Boolean);
      if (Object.keys(upd).length > 0) result.updatedAttrs = upd;
    }
    return result;
  }

  async describeAvatar(attrs: AvatarAttrs, dialog: ChatTurn[]): Promise<string> {
    const system = `你是幼儿园游戏「maliang」的形象设计师。根据小朋友在创建形象对话里的属性与原话，写一段给生图模型的中文外观描述。
硬规则（每一条都必须遵守；双手和头顶是游戏里贴纸装扮的位置，必须留空）：
1. 双手必须空着、自然垂在身体两侧——绝不写 抱着/拿着/手持/举着/捧着/牵着 任何东西，也绝不写 叉腰/合十/交叠/抱胸/插兜/背手 这类占手姿势（手上是贴纸装扮的位置，还要留着拿东西）。
2. 头顶空着——绝不写 帽子/皇冠/头盔/头纱 任何戴在头顶的东西；连帽衫可以穿但兜帽垂在脑后不戴起来；发卡、蝴蝶结只能别在侧边头发或胸前。
3. 小朋友的喜好一律转译成【衣服上的元素】：喜欢恐龙→恐龙图案连帽衫或衣服上的小恐龙刺绣，不是抱恐龙玩偶、也不是恐龙头套；喜欢踢球→足球图案T恤或运动鞋，不是抱着球。
4. 只描述这一个孩子本身的外观（发型、衣服、颜色、图案、配饰、表情），不出现第二个角色、宠物、玩具、背景或道具。
5. 小朋友的原话优先（「会发光的头发」就写会发光的头发），比选项词更宝贵。
6. 2~3 句以内，具体、可画，不写画风/构图/背景——服务端会统一追加。
只输出描述文字本身，不要 JSON、不要引号、不要解释。`;
    const dialogText = dialog.map((t) => `${t.role === 'child' ? '小朋友' : '点点'}：${t.text}`).join('\n');
    const a = attrs;
    const attrText = [
      a.gender && `性别=${a.gender}`, a.hairstyle && `发型=${a.hairstyle}`, a.outfit && `衣服=${a.outfit}`,
      a.color && `主色=${a.color}`, a.motifs.length > 0 && `喜欢的图案=${a.motifs.join('、')}`,
      a.accessory && `配饰=${a.accessory}`, a.extras.length > 0 && `其他=${a.extras.join('、')}`,
    ].filter(Boolean).join('，') || '（属性很少，请补得可爱些）';
    const user = `属性：${attrText}\n对话原文：\n${dialogText || '（无）'}`;
    // 违禁措辞（持物/头顶遮挡）→ 带着违规原文重试一次；仍违规或 LLM 失败 → 确定性兜底模板
    try {
      let desc = (await this.#client.chatText(this.#model, [
        { role: 'system', content: system }, { role: 'user', content: user },
      ])).trim();
      if (avatarDescForbidden(desc)) {
        desc = (await this.#client.chatText(this.#model, [
          { role: 'system', content: system },
          { role: 'user', content: `${user}\n\n上一稿违反了硬规则（出现了持物或头顶戴东西的措辞）：「${desc}」。重写：手里的东西改成衣服上的图案，头顶的东西去掉，姿势改成双手自然垂在身体两侧——双手必须空着、头顶必须留空、不许叉腰合十。` },
        ])).trim();
      }
      if (desc && !avatarDescForbidden(desc)) return desc;
    } catch {
      // 走兜底
    }
    return composeAvatarDesc(attrs);
  }

  async refineAvatar(description: string, childRequest: string): Promise<string> {
    const system = `你是幼儿园游戏「maliang」的形象设计师。小朋友看到自己刚生成的形象后提了一个修改。
把修改合并进外观描述：只改小朋友点名的那一处，其余部分保持原意、尽量原词保留。
硬规则与原描述相同（双手和头顶是贴纸装扮的位置必须留空）：双手空着绝不持物（喜好转译为衣服上的元素）、
头顶空着绝不戴帽子/皇冠（小朋友要求戴头顶物时改成别在侧边头发或胸前的样式）、双手自然垂在身体两侧绝不叉腰/合十/交叠、只有这一个孩子、不写画风/构图/背景。
只输出修改后的完整描述文字，不要 JSON、不要引号、不要解释。`;
    const user = `当前描述：${description}\n小朋友想改：${childRequest}`;
    try {
      let desc = (await this.#client.chatText(this.#model, [
        { role: 'system', content: system }, { role: 'user', content: user },
      ])).trim();
      if (avatarDescForbidden(desc)) {
        desc = (await this.#client.chatText(this.#model, [
          { role: 'system', content: system },
          { role: 'user', content: `${user}\n\n上一稿违反了硬规则（出现了持物或头顶戴东西的措辞）：「${desc}」。重写：手里的东西改成衣服上的图案，头顶的东西去掉，姿势改成双手自然垂在身体两侧——双手必须空着、头顶必须留空、不许叉腰合十。` },
        ])).trim();
      }
      if (desc && !avatarDescForbidden(desc)) return desc;
    } catch {
      // 走兜底
    }
    // LLM 失败/重试后仍违规：合法要求原样追加（不丢小朋友的话，生图仍能受益）；
    // 要求本身违规（如「戴大帽子」，2026-07-15 生产对抗用例实锤从这里漏进生图）→ 原描述原样返回。
    if (avatarDescForbidden(childRequest)) return description;
    return `${description}。按小朋友的要求调整：${childRequest}`;
  }

  async guideBuild(state: CreationState, childInput: string): Promise<GuideBuildResult> {
    const build = state.build;
    const bp = build ? findBlueprint(build.blueprintId) : undefined;
    // 蓝图丢了（不该发生）：兜底 done，绝不把孩子卡在半开会话里
    if (!build || !bp) return { replyText: '我们下次再拼好不好？', done: true };

    // 正在被回答的槽 = 上一轮问过的、还没填上的那个（首轮 askedSlots 为空 → 无回答槽，只提问）。
    const askedSlot = build.askedSlots.at(-1);
    const answering = askedSlot && !build.filled[askedSlot] ? bp.slots.find((s) => s.slotId === askedSlot) : undefined;
    const filledLines = Object.entries(build.filled)
      .map(([sid, pid]) => `${sid}=${findPart(pid)?.name ?? pid}`).join('，') || '（还没放任何零件）';
    // 把每个未填必填槽的功能线索 + 兼容零件（id+name）摊给 LLM：提问用 functionHint，解析答案用零件表。
    const missing = requiredSlots(bp).filter((s) => !build.filled[s.slotId]);
    const slotLines = missing.map((s) => {
      const parts = partsForSlot(s.accept).map((p) => `${p.id}(${p.name})`).join(' ');
      return `${s.slotId}: 功能线索「${s.functionHint}」 兼容零件 ${parts}`;
    }).join('\n');
    const answeringLine = answering
      ? `小朋友正在回答的槽是「${answering.slotId}」，它的兼容零件：${partsForSlot(answering.accept).map((p) => `${p.id}(${p.name})`).join(' ')}。把小朋友这句话认成其中一个零件的 id 填进 filledPartId/filledSlotId。`
      : '这是第一轮，小朋友刚说要拼，还没有在回答任何槽——直接问第一个槽的功能就好，别填零件。';

    const system = `你是幼儿游戏里温柔的小神仙「点点」，正带小朋友把一个「${bp.name}」用积木一块一块拼出来。
拼装的教育核心是「分解+组合」：你只问【功能】，让小朋友自己想到该放什么零件；【绝对不能】直接说出零件的名字（说了就成了报菜单，不是搭建）。
已经放好的零件：${filledLines}
还缺的槽（一次只问一个，按下面顺序挑第一个还没填的问）：
${slotLines || '（都放好了）'}
${answeringLine}
规则：把小朋友这句话对应的零件填进去后，如果还有缺的必填槽，就问下一个槽的功能（用它的功能线索，改写成温暖童趣的问句，配上那个槽的兼容零件 id 作 optionIds）；如果必填槽都放好了、或小朋友说「就这样/好了/够了」，就 done=true 收尾。
如果小朋友说不想拼了（「算了」「不要了」这类反悔），就 cancelled=true，replyText 给一句温柔的话，别再问、别落成。
严格只输出 JSON：{"replyText":"要对小朋友说的话(中文,温暖童趣,≤两句,只问功能绝不出现零件名)","done":true或false,"cancelled":true或false,"filledSlotId":"这轮填了哪个槽(没填就省略)","filledPartId":"填了哪个零件id(没填就省略)","askSlotId":"done=false时下一个要问的槽id","question":"done=false时的功能问句(不含零件名)","optionIds":["done=false时该槽的兼容零件id"]}`;
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
      return { replyText: str(raw.replyText, '好呀，那我们不拼啦！'), done: false, cancelled: true };
    }
    // 解析 LLM 填的零件：必须是「正在回答的槽」+ 与该槽兼容的真实零件，兜住幻觉（LLM 乱填别的槽/不存在的零件一律丢弃）。
    let filled: { slotId: string; partId: string } | undefined;
    if (answering) {
      const partId = str(raw.filledPartId, '');
      const part = partId ? findPart(partId) : undefined;
      if (part && part.fitSlots.includes(answering.accept)) {
        filled = { slotId: answering.slotId, partId: part.id };
      }
    }
    // 落成判定：把这轮的填算进去后，必填槽是否全满
    const filledNow = { ...build.filled };
    if (filled) filledNow[filled.slotId] = filled.partId;
    const stillMissing = requiredSlots(bp).filter((s) => !filledNow[s.slotId]);
    const done = raw.done === true || stillMissing.length === 0;
    if (done) {
      return { replyText: str(raw.replyText, `好啦，我们的${bp.name}拼好啦！`), done: true, filled };
    }
    // 追问下一个槽：优先用 LLM 给的 askSlotId（须是真实未填必填槽），无效则确定性取第一个未填必填槽。
    const askId = str(raw.askSlotId, '');
    const next = stillMissing.find((s) => s.slotId === askId) ?? stillMissing[0];
    const compatibleIds = new Set(partsForSlot(next.accept).map((p) => p.id));
    const llmIds = Array.isArray(raw.optionIds) ? raw.optionIds.map(String).filter((id) => compatibleIds.has(id)) : [];
    const optionIds = llmIds.length > 0 ? llmIds : [...compatibleIds];
    return {
      replyText: str(raw.replyText, `${next.functionHint}？`),
      done: false,
      question: str(raw.question, next.functionHint),
      slotId: next.slotId,
      optionIds,
      filled,
    };
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

  async designTaskChain(ctx: { name: string; personality: string }): Promise<ChainStep[]> {
    // 产物由调用方 validateChainSteps 把关（步数/type/wishAbility/自言自语纪律），
    // 这里只负责生成——解析不出就回空数组，让调用方走模板回退。
    const system = `你在为幼儿园小朋友的沙盒游戏设计一个村民的「委托链」：3-5 个小委托，围绕同一个小主题层层递进
（例如面包师：想认识邻居 → 想要一个烤炉 → 请大家来吃面包），体现这个村民的人设。
村民：${ctx.name}。人设：${ctx.personality}。
每一步是一个对象，字段：
- type：四选一。deliver=请小朋友把一句话带给别的村民；bring=请小朋友把别的村民带过来；visit=请小朋友去某个地点看一看；wish=一个要小仙子的魔法才能实现的念想
- type=wish 时必须带 wishAbility，五选一：create_prop=变出一样东西 / create_character=造一个新伙伴 / create_sticker=做一张贴纸 / play_game=开一局大家一起玩的游戏 / guide_to=让小仙子带路去远处；并带 desire=想要的东西的一句话描述
- leak：小朋友路过时的自言自语（漏话）。铁律：只说自己想什么，绝不出现「你可以」「要不要」「告诉我」这类对着小朋友说话的词
- ask：小朋友主动搭话时的请求话术（这里可以说「请你/帮我」）
- thanks：这一步完成时的道谢
注意：deliver/bring/visit 一律不写具体人名或地点名——游戏发起时会现选目标，话术里用「他/那个地方」指代。
全部中文，温暖童趣，每句不超过 40 字。绝不包含暴力、恐怖、武器、成人内容。
严格只输出 JSON：{"steps":[{"type":"...","leak":"...","ask":"...","thanks":"...","wishAbility":"仅wish","desire":"仅wish"},...]}`;
    const content = await this.#client.chatText(
      this.#model,
      [
        { role: 'system', content: system },
        { role: 'user', content: `请为「${ctx.name}」设计委托链。` },
      ],
      { jsonObject: true },
    );
    let raw: Record<string, unknown> = {};
    try {
      raw = JSON.parse(stripFences(content)) as Record<string, unknown>;
    } catch {
      raw = {};
    }
    return Array.isArray(raw.steps) ? (raw.steps as ChainStep[]) : [];
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
