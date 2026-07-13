// 心愿漏话（wish leak）：角色不经意漏出「想做什么/在做什么」，让小朋友自己发现玩法。
// 见 docs/wish-leak-design.md。
//
// 核心纪律——漏话是【自言自语】，不是广告：
//   ✗「想去哪儿玩呀？告诉我，我带你去！」  ← 在告诉小朋友「你可以让我做 X」
//   ✓「我昨天飞过一个地方，那儿的花会发光呢…可惜好远好远。」← 只说自己想要什么
// 每一句都必须过这一关：把「你」字去掉后还成立吗？出现「你可以」「要不要」「告诉我」就是广告，重写。
//
// 词库是静态的（形状照抄 greetings.ts）：零 LLM 成本、确定性、可单测、可预制 TTS。

/** 一个心愿：勾哪个玩法、怎么漏、怎么想、兑现了怎么谢。 */
export interface WishDef {
  /** 勾的玩法能力（与 ABILITY_DESC / BASE_ABILITIES 同名）。 */
  ability: string;
  /** 漏话：小朋友在旁边时自言自语的话。随机选一条。 */
  leaks: string[];
  /** 注入该村民 routeIntent prompt 的背景——让它被搭话时能自然接上自己的心愿。 */
  context: string;
  /** 心愿达成时的道谢（走 pushPraiseTts，村民自己的音色）。 */
  thanks: string[];
  /**
   * 兑现它要花掉一朵小红花吗（造物/造角色/造贴纸都扣 1 朵，见 server.ts spendFlower）。
   *
   * 这个标记扛着一个死锁：心愿委托优先于跑腿委托，而跑腿是赚小红花的路子。
   * 小朋友花光了花、心愿池又只剩造物类 → 唯一能接的活是造物，但造不起；
   * 跑腿委托被心愿挡住 → 赚不回花 → 永久卡死。所以【买不起就不勾】：
   * 没花时这类心愿既不进委托候选、也不漏话，让位给跑腿委托去赚花。
   * 顺带还消掉一种挫败——被勾起了兴趣，凑过去却发现造不起。
   */
  costsFlower: boolean;
}

/**
 * 能力 → 心愿。只收录【小朋友还不知道自己能玩】的玩法：
 * 造物/造角色/造贴纸/玩游戏/引路。走路、聊天这类基础交互不必勾——intro 已经教过手势了。
 */
export const WISHES: Record<string, WishDef> = {
  create_prop: {
    ability: 'create_prop',
    costsFlower: true,
    leaks: [
      '我家门口空落落的…要是有棵会开花的树，该多好呀。',
      '唉…下雨天我都没地方躲，要是这儿有个小亭子就好啦。',
      '我昨天梦见一个大风车，呼啦呼啦地转…醒来就没有啦。',
    ],
    context: '你心里一直盼着一样还没有的东西（门口的花树、躲雨的小亭子、会转的大风车之类）——你自己变不出来，只是偶尔会想起它。',
    thanks: [
      '哇——它真的出现啦！谢谢你，谢谢你！',
      '我一直想要的东西…你居然帮我弄来啦！',
    ],
  },
  create_character: {
    ability: 'create_character',
    costsFlower: true,
    leaks: [
      '一个人搭积木好没意思…要是有个小伙伴陪我就好啦。',
      '我这儿有两块小饼干呢…可是没人跟我一起吃。',
      '要是能有只毛茸茸的小家伙跟着我，我就天天带着它。',
    ],
    context: '你心里有点孤单，一直盼着能多一个玩伴——你自己变不出来，只是偶尔会念叨一句。',
    thanks: [
      '哇！它是来陪我的吗？我好开心呀！',
      '我不再是一个人啦！谢谢你！',
    ],
  },
  create_sticker: {
    ability: 'create_sticker',
    costsFlower: true,
    leaks: [
      '别人衣服上都有亮晶晶的小星星…就我这儿光秃秃的。',
      '我好想在身上贴一个小太阳呀，那样走到哪儿都是暖暖的。',
      '这面墙白白的，什么都没有…要是能有点花花绿绿的就好了。',
    ],
    context: '你羡慕别人身上花花绿绿的小图案（小星星、小太阳之类），自己却光秃秃的——你自己做不出来，只是偶尔会瞄一眼别人的。',
    thanks: [
      '给我的吗？我要贴在最显眼的地方！',
      '哇，亮晶晶的！我也有啦！',
    ],
  },
  play_game: {
    ability: 'play_game',
    costsFlower: false,
    leaks: [
      '我捡到一个球！可是…一个人踢好像不好玩。',
      '我以前跟好多小朋友一起跑来跑去…现在没人陪我跑啦。',
      '嘿…我藏得可好了，可是没人来找我呀。',
    ],
    context: '你憋着一股想跑想闹的劲儿，特别想跟一群人一起玩个热闹的游戏——但你自己张罗不起来，只是偶尔嘟囔一句。',
    thanks: [
      '刚才太好玩啦！我们下次还玩！',
      '哈哈哈！我好久没这么开心过啦！',
    ],
  },
  guide_to: {
    ability: 'guide_to',
    costsFlower: false,
    leaks: [
      '我昨天飞过一个地方，那儿的花会发光呢…可惜好远好远。',
      '山那边好像有什么在闪…我一个人不敢去看。',
      '这个世界大着呢…好多地方我都还没带人去过。',
    ],
    context: '你知道一些远处的好地方，心里一直惦记着想去看看，但一个人不敢去。',
    thanks: [
      '我们真的到啦！我一个人可不敢来呢。',
      '你看，我没骗你吧！这儿好看吧！',
    ],
  },
};

/** 心愿池耗尽（玩法全被发现）后的纯氛围自语——不勾任何玩法，只是让世界有活气。 */
export const IDLE_DOING: string[] = [
  '我在数天上的云…一朵，两朵，哎呀又飘走一朵。',
  '哼哼，哼哼…这是我自己编的歌哦。',
  '今天的风闻起来甜甜的，是不是有人在烤饼干呀。',
  '我的影子怎么变长啦…是不是它也在长个子。',
  '嘘——我在听小虫子说话呢。',
];

/** 全部可勾的玩法能力（心愿库的键）。 */
export const WISH_ABILITIES: readonly string[] = Object.keys(WISHES);

/** 字符串 → 稳定哈希（同一 id 每次结果一致；与 greetings.styleForCharacter 同款）。 */
function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
  return h;
}

/**
 * 某村民当下认领的心愿：从【玩家还没发现的玩法】里按 characterId 稳定挑一个。
 * 同一村民对同一玩家永远同一个心愿（不落库，纯函数），直到那个玩法被发现——
 * 发现后池子变小，它自然改口说别的，全发现完则返回 null（回落 IDLE_DOING）。
 *
 * 稳定性是设计的一部分：小朋友第二次路过时听见的还是同一个念想，
 * 才会觉得「这个人一直想要棵树」，而不是「这人每次胡说八道」。
 */
export function wishFor(
  characterId: string,
  discovered: readonly string[],
  canAfford = true,
): WishDef | null {
  const pool = WISH_ABILITIES.filter((a) => {
    if (discovered.includes(a)) return false;
    if (!canAfford && WISHES[a]!.costsFlower) return false; // 买不起就不勾（见 costsFlower）
    return true;
  });
  if (pool.length === 0) return null;
  return WISHES[pool[hash(characterId) % pool.length]!]!;
}

/** 该村民这次要漏的那句话（心愿池空则回落纯氛围自语）。rng 可注入以便测试确定性。 */
export function pickLeak(
  characterId: string,
  discovered: readonly string[],
  rng: () => number = Math.random,
  canAfford = true,
): string {
  const wish = wishFor(characterId, discovered, canAfford);
  const pool = wish ? wish.leaks : IDLE_DOING;
  return pool[Math.floor(rng() * pool.length)]!;
}

/** 心愿达成时的道谢词。rng 可注入。 */
export function pickThanks(wish: WishDef, rng: () => number = Math.random): string {
  return wish.thanks[Math.floor(rng() * wish.thanks.length)]!;
}
