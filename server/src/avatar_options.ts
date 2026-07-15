import type { AvatarAttrs, AvatarCategory, AvatarGuideState, AvatarOption, GuideAvatarResult, PlayerOnboardingProfile } from './types.ts';

/**
 * 玩家形象 onboarding 的选项库（见 docs/onboarding-avatar-redesign-design.md §2.2）。
 * 与造角色 creation_options.ts / 造物 prop_creation_options.ts 平行，但类别是玩家外观专属。
 *
 * - 每轮 guideAvatar 从某一类别里挑 2–4 个 id 当选项，客户端渲染图标卡。
 * - iconAsset 由 P3 图标生成管线填入（/assets/:hash）；生成前为空串（客户端回落文字卡）。
 * - color 类刻意不生成图标——客户端 _option_button 已支持纯色块渲染，按 id 出色块。
 * - 选项只是脚手架：开放语音优先（「我要会发光的头发」原话进属性，不归一成库里的词）。
 */

/** 形象对话可问的类别（gender 第一问，生图必需）。 */
export const AVATAR_CATEGORIES: readonly AvatarCategory[] = [
  'gender', 'hairstyle', 'outfit', 'color', 'motif', 'accessory',
];

/** 需要生成图标的类别（color 除外——客户端渲染色块）。 */
export const AVATAR_ICON_CATEGORIES: readonly AvatarCategory[] = [
  'gender', 'hairstyle', 'outfit', 'motif', 'accessory',
];

function opt(id: string, category: AvatarCategory, label: string): AvatarOption {
  return { id, category, label, iconAsset: '' };
}

/** 形象选项库全表。id 加 av_ 前缀，不与造角色/造物/贴纸库撞。 */
export const AVATAR_OPTIONS: readonly AvatarOption[] = [
  // gender 性别（第一问，生图必需）
  opt('av_boy', 'gender', '小男生'), opt('av_girl', 'gender', '小女生'),
  // hairstyle 发型
  opt('av_hair_short', 'hairstyle', '短短的头发'), opt('av_hair_long', 'hairstyle', '长长的头发'),
  opt('av_hair_twin', 'hairstyle', '双马尾'), opt('av_hair_pony', 'hairstyle', '高马尾'),
  opt('av_hair_curly', 'hairstyle', '卷卷头'), opt('av_hair_buns', 'hairstyle', '丸子头'),
  // outfit 衣服风格
  opt('av_out_sport', 'outfit', '运动服'), opt('av_out_dress', 'outfit', '蓬蓬裙'),
  opt('av_out_overall', 'outfit', '背带裤'), opt('av_out_hoodie', 'outfit', '连帽衫'),
  opt('av_out_tee', 'outfit', 'T恤短裤'), opt('av_out_sweater', 'outfit', '毛毛衣'),
  // color 主色（色块渲染，无图标）
  opt('av_col_red', 'color', '红色'), opt('av_col_orange', 'color', '橙色'),
  opt('av_col_yellow', 'color', '黄色'), opt('av_col_green', 'color', '绿色'),
  opt('av_col_blue', 'color', '蓝色'), opt('av_col_purple', 'color', '紫色'),
  opt('av_col_pink', 'color', '粉色'), opt('av_col_white', 'color', '白色'),
  // motif 喜欢的图案元素（转译为穿戴元素，绝不手持）
  opt('av_mot_star', 'motif', '星星'), opt('av_mot_dino', 'motif', '小恐龙'),
  opt('av_mot_flower', 'motif', '小花'), opt('av_mot_rainbow', 'motif', '彩虹'),
  opt('av_mot_ball', 'motif', '足球'), opt('av_mot_heart', 'motif', '爱心'),
  opt('av_mot_butterfly', 'motif', '蝴蝶'), opt('av_mot_rocket', 'motif', '小火箭'),
  opt('av_mot_car', 'motif', '小汽车'), opt('av_mot_note', 'motif', '音符'),
  // accessory 小配饰
  opt('av_acc_cap', 'accessory', '棒球帽'), opt('av_acc_crown', 'accessory', '小皇冠'),
  opt('av_acc_clip', 'accessory', '发卡'), opt('av_acc_scarf', 'accessory', '围巾'),
  opt('av_acc_glasses', 'accessory', '小眼镜'), opt('av_acc_bow', 'accessory', '蝴蝶结'),
  opt('av_acc_backpack', 'accessory', '小背包'), opt('av_acc_strawhat', 'accessory', '草帽'),
];

/**
 * 图标生图主体描述（英文；P3 走 buildIconPrompt 统一扁平贴纸画风）。
 * 沿造角色 ICON_PROMPTS 的教训：同类别锁同构图/同基调只变主体，跨类别拉开差异；
 * 发型类锁「同一个极简蛋形头 + 点眼」只变头发，衣服/配饰类衣物平铺无人身、no face。
 * color 不在此表——客户端渲染色块。
 */
export const AVATAR_ICON_PROMPTS: Record<string, string> = {
  // gender → 极简全身小人（同构图同色调，只有轮廓特征不同）
  av_boy: 'a minimal cute flat cartoon full-body little boy with short hair, plain solid clothes, standing front view, arms down at the sides, hands empty, simple dot eyes and smile, identical pose and framing to the girl icon',
  av_girl: 'a minimal cute flat cartoon full-body little girl with shoulder-length hair, plain solid dress, standing front view, arms down at the sides, hands empty, simple dot eyes and smile, identical pose and framing to the boy icon',
  // hairstyle → 同一个极简蛋形头，只变头发（发色统一深棕，防跟颜色轮打架）
  av_hair_short: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown very short neat hair, identical head shape and framing to the other hairstyle icons',
  av_hair_long: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown long straight hair flowing past the shoulders, identical head shape and framing to the other hairstyle icons',
  av_hair_twin: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown hair in two pigtails with small ties, identical head shape and framing to the other hairstyle icons',
  av_hair_pony: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown hair in one high ponytail, identical head shape and framing to the other hairstyle icons',
  av_hair_curly: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown fluffy curly hair with many round curls, identical head shape and framing to the other hairstyle icons',
  av_hair_buns: 'a minimal flat icon of one simple egg-shaped cartoon head with tiny dot eyes, dark brown hair in two round buns on top, identical head shape and framing to the other hairstyle icons',
  // outfit → 衣服平铺（no person, no face；统一浅灰基色防跟颜色轮打架）
  av_out_sport: 'a flat lay icon of a cute kids sport tracksuit jacket and pants with two side stripes, light grey base color, clothes only, no person, no face',
  av_out_dress: 'a flat lay icon of a cute kids puffy tutu dress with layered skirt, light grey base color, clothes only, no person, no face',
  av_out_overall: 'a flat lay icon of cute kids denim overalls with front pocket and shoulder straps, clothes only, no person, no face',
  av_out_hoodie: 'a flat lay icon of a cute kids hoodie with hood and front pocket, light grey base color, clothes only, no person, no face',
  av_out_tee: 'a flat lay icon of a cute kids t-shirt and shorts set, light grey base color, clothes only, no person, no face',
  av_out_sweater: 'a flat lay icon of a cute kids fluffy knitted sweater with visible knit texture, light grey base color, clothes only, no person, no face',
  // motif → 扁平图案符号（no face 除非本就是脸；参考贴纸库画法）
  av_mot_star: 'a cute plump flat five-point star, symbol only, no face',
  av_mot_dino: 'a cute flat green baby dinosaur side view with small back spikes, simple sticker style',
  av_mot_flower: 'a cute simple flat daisy flower with rounded petals, no face',
  av_mot_rainbow: 'a cute flat rainbow arc with a small cloud at each end, no face',
  av_mot_ball: 'a cute flat classic black and white soccer ball, symbol only, no face',
  av_mot_heart: 'a cute glossy flat heart, symbol only, no face',
  av_mot_butterfly: 'a cute flat butterfly with symmetric patterned wings, top view, no face',
  av_mot_rocket: 'a cute flat cartoon rocket with round window flying upward with small flame, no face',
  av_mot_car: 'a cute flat cartoon toy car side view with big round wheels, no face',
  av_mot_note: 'a cute plump flat music note, symbol only, no face',
  // accessory → 单件配饰（object only, no person, no face）
  av_acc_cap: 'a cute flat kids baseball cap side view, single object, no person, no face',
  av_acc_crown: 'a cute flat little golden crown with round jewel tips, single object, no person, no face',
  av_acc_clip: 'a cute flat hair clip with a small flower on it, single object, no person, no face',
  av_acc_scarf: 'a cute flat cozy knitted scarf loosely folded, single object, no person, no face',
  av_acc_glasses: 'a cute flat pair of round kids glasses, single object, no person, no face',
  av_acc_bow: 'a cute flat ribbon bow, single object, no person, no face',
  av_acc_backpack: 'a cute flat small kids backpack front view, single object, no person, no face',
  av_acc_strawhat: 'a cute flat straw sun hat with a ribbon band, single object, no person, no face',
};

/** 取形象图标的生图 prompt（color 无图标不在表内；未知 id 回退 label 兜底）。 */
export function avatarIconPrompt(id: string): string {
  return AVATAR_ICON_PROMPTS[id] ?? `a cute flat sticker icon of ${id}`;
}

/**
 * 追问每个类别的问法（mock 固定文案 + LLM 超时降级链用；真实由 LLM 按点点口吻+功能场景生成）。
 * 问句带功能小场景（A3 合用种子的轻量版），但任何选择都对，绝不评判。
 */
export const AVATAR_ASK: Record<AvatarCategory, string> = {
  gender: '你是小男生，还是小女生呀？',
  hairstyle: '你想要什么样的头发呀？',
  outfit: '魔法森林里要跑要跳还要爬树，穿什么最方便呀？',
  color: '你的衣服想要什么颜色的呀？',
  motif: '你最喜欢什么图案呀？点点把它画到你衣服上！',
  accessory: '再挑一个小宝贝戴上好不好？',
};

const BY_ID = new Map(AVATAR_OPTIONS.map((o) => [o.id, o]));
const BY_LABEL = new Map(AVATAR_OPTIONS.map((o) => [o.label, o]));

/** 按类别取形象选项。 */
export function avatarOptionsByCategory(category: AvatarCategory): AvatarOption[] {
  return AVATAR_OPTIONS.filter((o) => o.category === category);
}

/** 按 id 查形象选项（未知 undefined）。 */
export function findAvatarOption(id: string): AvatarOption | undefined {
  return BY_ID.get(id);
}

/** 按中文 label 查形象选项（客户端/ASR 可能给 label 而非 id）。 */
export function findAvatarOptionByLabel(label: string): AvatarOption | undefined {
  return BY_LABEL.get(label.trim());
}

/** 生图描述里绝不能出现的持物措辞（describeAvatar 硬规则的机器判据，单测/重试共用）。 */
export const AVATAR_FORBIDDEN_DESC = /(抱着|拿着|手持|举着|捧着|牵着|手里)/;

/**
 * 把形象属性汇成纯外观中文描述——mock 与 LLM 降级链共用的确定性兜底。
 * 硬规则内建：双手空着；图案是「印在衣服上」的穿戴元素，绝不手持（治「抱着玩偶」病灶）。
 */
export function composeAvatarDesc(a: AvatarAttrs): string {
  const gender = a.gender === '小男生' ? '小男孩' : a.gender === '小女生' ? '小女孩' : '小朋友';
  const parts: string[] = [`一个可爱的${gender}`];
  if (a.hairstyle) parts.push(`留着${a.hairstyle}`);
  parts.push(`穿着${a.color ? `${a.color}的` : ''}${a.outfit ?? '舒服的衣服'}`);
  if (a.motifs.length > 0) parts.push(`衣服上印着${a.motifs.join('和')}图案`);
  if (a.accessory) parts.push(`还带着${a.accessory}`);
  for (const e of a.extras) parts.push(e);
  parts.push('双手空空的自然垂在身边，没有拿任何东西');
  return parts.join('，');
}

/**
 * onboarding 档案 → 对话 prompt 里的一句喜好摘要（IntentContext.childProfile）。
 * 只挑「角色能自然聊起」的料：称呼/图案/主色/形象创作原话/refine 小坚持；没料返回 undefined
 * （无档案的老玩家一个字节都不多注入）。纯函数，可单测。
 */
export function onboardingProfileNote(p: PlayerOnboardingProfile | undefined): string | undefined {
  if (!p) return undefined;
  const bits: string[] = [];
  const call = p.nickname || p.name;
  if (call) bits.push(`TA叫「${call}」`);
  const a = p.attrs;
  if (a) {
    if (a.motifs.length > 0) bits.push(`最喜欢的图案是${a.motifs.join('、')}`);
    if (a.color) bits.push(`最喜欢${a.color}`);
    const extras = a.extras.slice(0, 2);
    if (extras.length > 0) bits.push(`创建形象时说过「${extras.join('」「')}」`);
  }
  if (p.refineNotes.length > 0) bits.push(`对自己形象的小坚持：「${p.refineNotes.join('」「')}」`);
  if (bits.length === 0) return undefined;
  return bits.join('，');
}

/** 提前收工的口头信号（「就这样」类；含不耐烦——onboarding 无反悔语义，不想选=done）。 */
const AVATAR_EARLY_DONE = /(就这样|好了|够了|够啦|可以了|不想选|不选了|算了)/;

/**
 * 形象引导一轮的【确定性】推进——mock 适配器与「LLM 失败/超时降级链」共用的同一实现
 * （docs/onboarding-avatar-redesign-design.md §3.3：宁可退到平庸也绝不卡住小朋友）。
 * 行为契约与 LLM 路径一致：按图标 label 认属性；开放语音（非库内 label）整句收进上一轮
 * 问的类别、不归一；性别第一问；性别+2项外观、说「就这样」、或超轮即 done；无 cancelled。
 * 纯函数：不改 state，本轮增量放 updatedAttrs（motifs/extras 为增量后全量）。
 */
export function deterministicGuideAvatar(state: AvatarGuideState, childInput: string): GuideAvatarResult {
  const attrs: AvatarAttrs = { ...state.attrs, motifs: [...state.attrs.motifs], extras: [...state.attrs.extras] };
  const updated: Partial<AvatarAttrs> = {};
  const text = childInput.trim();
  const lastAsked = state.askedCategories.at(-1) as AvatarCategory | undefined;
  const isKnownLabel = AVATAR_OPTIONS.some((o) => text.includes(o.label));
  if (lastAsked && text && !isKnownLabel && !AVATAR_EARLY_DONE.test(text)) {
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
  const early = AVATAR_EARLY_DONE.test(text);
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
}
