// 剧本生成层（realtime-primitives P5 / docs/realtime-game-primitives-design §9）。
//
// 链路：口语「我们来踢球吧」→ routeIntent 识别 play_game → 本模块把它写成一段【真 TS】剧本
//       → checkScreenplay 过 typecheck（失败带错回喂重生成 1-2 次）→ 返回过关草案。
// 之后 WS 层用 buildStageOptsFromDraft 把 cast 映射到真实村民，交 StageDirector.startStage 开演。
//
// 本模块【与模型无关】：retry 环接收一个 draftFn(messages)→原始 JSON 文本，openrouter adapter 用强模型
// 实现它、mock 直接给确定性草案绕过环。这样重试逻辑（P5 成败关键之一）可用假 draftFn 单测。
// 防腐纪律（§3）：生成的脚本只写【规则】，不写玩法名判断、不臆造原语——全在 system prompt 里约束。

import type { ScreenplayDraft, ScreenplayGenContext } from './types.ts';
import type { StageStartOpts } from './stage_session.ts';
import type { StageActorInfo } from './stage_types.ts';
import type { WorldStore } from './persistence.ts';
import type { WorldHub } from './world_hub.ts';
import { DEFAULT_SCENE } from './types.ts';
import { checkScreenplay } from './screenplay_check.ts';
import { stageSdkDts, loadScreenplay } from './screenplays.ts';

/** 生成对话里的一条消息（与模型无关；openrouter adapter 映射成 ChatMessage）。 */
export interface GenMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

/** 一次原始生成：把对话喂给（强）模型，返回它吐的原始文本（应是 {cast,code} 的 JSON）。 */
export type DraftFn = (messages: GenMessage[]) => Promise<string>;

/** 生成层默认最多尝试次数（首次 + 带错重生成）。老板要求 1-2 次重试环。 */
export const DEFAULT_GEN_ATTEMPTS = 3;

function stripFences(s: string): string {
  return s.replace(/^\s*```(?:json)?/i, '').replace(/```\s*$/i, '').trim();
}

/**
 * 剧本生成 system prompt：角色 + 沙箱说明 + stage_sdk.d.ts 接口契约 + 防腐纪律 + 两个 few-shot 样例
 * + 输出格式。跨请求字节稳定（不含本轮游戏名），便于 prompt cache；本轮游戏/演员走 user 消息。
 */
export function buildGenSystem(): string {
  const dts = stageSdkDts();
  const soccer = loadScreenplay('soccer');
  const eagle = loadScreenplay('eagle_and_chicks');
  return `你是幼儿园游戏「maliang」的【游戏剧本作者】。小朋友说想玩一个游戏，你把这个游戏的【规则】写成一段在服务端沙箱里运行的 TypeScript 剧本。

## 剧本是什么
剧本是【一段异步函数体】（顶层可直接 await），不是模块：
- 没有 import / export / require / process / fetch / setTimeout —— 全局只有 stage、cast、console.log。
- 运行时把它剥掉类型后丢进 node:vm 执行；写错 API 或用了沙箱外的东西，会在类型检查关被拦下、无法开演。

## 你能用的全部 API（接口契约，务必严格遵守）
\`\`\`typescript
${dts}
\`\`\`

## 防腐纪律（最重要，违反直接作废）
你只写【游戏规则】：胜负、计分、幕次、生成/回收、判定编排（谁进了区域算谁分、谁被抓出局）。
你【绝不】写实时动作本身——球怎么滚、角色怎么追、怎么踢，都是客户端原语，孩子靠近球就能踢、follow 客户端本地跑。
- 绝不出现玩法名判断，例如 \`if (game === 'soccer')\`——脚本永远不该知道自己是哪个玩法。
- 能用现有原语（moveTo/say/do/follow/flee/stop/near/enter/region/spawnBall/prompt/countdown/score）就【绝不臆造】新 API；契约里没有的方法一律不存在。
- 自检：你写的这段逻辑换个玩法还用得上吗？用得上（球怎么滚）是原语、不该你写；用不上（进这个门算谁分）才是规则、写进脚本。

## 演员与坐标
- 我会告诉你当前场上有哪些村民可当演员、有没有小朋友在玩。你用 \`cast('角色名')[0]\` 取一个命名演员；\`stage.player\` 是小朋友（没有小朋友在玩时为 null，用前先判空）。
- cast 里的角色数【不得超过】可用村民数。soccer 这类只用球+区域+玩家的玩法，不需要命名演员（cast 为空）。
- 世界是 150×150 的环面格子坐标（中心约 75,75）。任何 region/spawnBall 的落点、时长、判定距离都【从 stage.params 读且必须带自跑默认值】：\`Number(stage.params.gameSec ?? 120)\`、\`(stage.params.center as Spot) ?? { x: 75, y: 75 }\`。绝不把某个场景的具体坐标写死。
- 剧本要能在【没有任何 params】时也自己跑起来（默认值兜底）。

## 两个样例（照它们的形状写，坐标/时长都走 params 默认值）
### 样例 A —— 踢球（C 档球玩法：球+区域+服务端进球判定+计分，踢球本身不写进脚本）
\`\`\`typescript
${soccer}
\`\`\`
### 样例 B —— 老鹰抓小鸡（纯复用现有原语：链式 follow + near 抓捕，无新 API）
\`\`\`typescript
${eagle}
\`\`\`

## 输出格式
严格只输出 JSON，无 markdown 代码块、无多余文字：
{"cast":["角色名",...],"code":"剧本源码（异步函数体，不含 import/export）"}
- code 是完整可运行的剧本源码字符串（换行用 \\n）。
- cast 有序列出 code 里 \`cast(...)\` 用到的角色名；不需要命名演员就给空数组 []。
- 开场用一句 \`await stage.narrate(...)\` 讲清怎么玩（面向 3 岁小朋友，简单温暖）。
- 剧本必须有明确的收场：走到 \`stage.end({ winner, praise })\`（praise 是给小朋友的一句夸奖）。
- 绝不包含暴力、恐怖、武器、成人内容。`;
}

/** 本轮 user 消息：孩子想玩什么 + 现在有哪些演员。 */
export function buildGenUser(ctx: ScreenplayGenContext): string {
  const roster = ctx.villagerNames.length > 0
    ? `当前场上可当演员的村民（共 ${ctx.villagerNames.length} 个）：${ctx.villagerNames.join('、')}。`
    : '当前场上没有别的村民可当演员（只能靠球/区域/小朋友本人来玩）。';
  const player = ctx.hasPlayer ? '有一个小朋友在玩（stage.player 可用）。' : '现在没有小朋友在玩（stage.player 为 null）。';
  return `小朋友想玩：「${ctx.gameDesc}」。\n${roster}\n${player}\n请把这个游戏的规则写成剧本。cast 里的角色数不要超过可用村民数；用不到命名演员就给空 cast。`;
}

/**
 * 带 typecheck 重试环的剧本生成（老板要求的 P5 三大关键之一）：
 * 生成 → 解析 {cast,code} → checkScreenplay 过 typecheck → 有诊断就把错误回喂、要求修，重生成，最多 maxAttempts 次。
 * 全部尝试都过不了（或始终解析不出 code）返回 null——调用方口头兜底、不开演。
 * draftFn 与模型无关，便于单测；真实 openrouter 用强模型实现它。
 */
export async function generateScreenplayWithRetry(
  draftFn: DraftFn,
  ctx: ScreenplayGenContext,
  maxAttempts = DEFAULT_GEN_ATTEMPTS,
): Promise<ScreenplayDraft | null> {
  const messages: GenMessage[] = [
    { role: 'system', content: buildGenSystem() },
    { role: 'user', content: buildGenUser(ctx) },
  ];
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let raw: string;
    try {
      raw = await draftFn(messages);
    } catch (err) {
      // 模型调用本身失败（超时/网络）：不重试同一条（多半还会失败），直接放弃走兜底。
      console.warn(`[screenplay-gen] 第 ${attempt} 次生成调用失败：${String(err)}`);
      return null;
    }
    const parsed = parseDraft(raw);
    if (!parsed) {
      // 解析不出 code：把原始输出当作 assistant 轮记下，要求它只输出规定 JSON。
      messages.push({ role: 'assistant', content: raw.slice(0, 4000) });
      messages.push({ role: 'user', content: '你的输出解析不出 {"cast":[...],"code":"..."} 这个 JSON。请【严格只输出】这个 JSON 对象，code 是剧本源码字符串（换行用 \\n），不要任何 markdown 或解释。' });
      continue;
    }
    const diags = checkScreenplay(parsed.code);
    if (diags.length === 0) {
      return parsed; // 过关
    }
    // typecheck 不过：带着诊断回喂，要求就地修（这是「智能编码」的关键——把编译器错误交回模型自纠）。
    messages.push({ role: 'assistant', content: raw.slice(0, 4000) });
    messages.push({
      role: 'user',
      content: `你上面的剧本没通过类型检查，报了这些错（对着接口契约修，别改玩法思路，只修 API 用法/类型）：\n${diags.slice(0, 12).map((d) => `- ${d}`).join('\n')}\n请重新输出【完整】的 {"cast":[...],"code":"..."} JSON，改正这些错误。`,
    });
  }
  return null;
}

/** 从模型原始输出解析 {cast,code}。code 必须非空字符串；cast 缺省空数组。解析不出返回 null。 */
export function parseDraft(raw: string): ScreenplayDraft | null {
  let obj: unknown;
  try {
    obj = JSON.parse(stripFences(raw));
  } catch {
    return null;
  }
  if (!obj || typeof obj !== 'object') return null;
  const o = obj as { code?: unknown; cast?: unknown };
  if (typeof o.code !== 'string' || o.code.trim().length === 0) return null;
  const cast = Array.isArray(o.cast) ? o.cast.map(String).filter((s) => s.trim().length > 0) : [];
  return { code: o.code, cast };
}

/** buildStageOptsFromDraft 的结果：能开演给 opts，人不够/无演给 reason（调用方口头兜底）。 */
export type BuildOptsResult =
  | { ok: true; opts: StageStartOpts }
  | { ok: false; reason: string };

/**
 * 把生成草案组成 StageDirector.startStage 要的开演参数：cast 有序映射到本场景真实村民
 * （与 stage_debut.buildDebut 同套路——演员 name 设成 cast 里的角色名，脚本 cast('老鹰') 才对上），
 * 有小朋友在玩则追加 player 演员。cast 比可用村民多 → 开不了（人不够）。
 * 坐标/时长走脚本自跑默认值（POI→坐标注入是后续工作，见 stage_sdk.d.ts Region 注释）。
 */
export function buildStageOptsFromDraft(
  draft: ScreenplayDraft,
  store: WorldStore,
  hub: WorldHub,
  worldId: string,
  playerId: string,
  sceneId: string = DEFAULT_SCENE,
): BuildOptsResult {
  // 本场景可当演员的村民（排除小仙子——她悬浮不走地面）。
  const villagers = store.listCharacters(worldId, sceneId).filter((c) => !c.isFairy);
  if (draft.cast.length > villagers.length) {
    return { ok: false, reason: `这个游戏要 ${draft.cast.length} 个小伙伴，场上只有 ${villagers.length} 个` };
  }
  const actors: StageActorInfo[] = draft.cast.map((role, i) => ({
    id: villagers[i].id,
    name: role, // 剧中角色名：cast('老鹰') 认的是这个，不是村民本名
    isPlayer: false,
    voiceId: villagers[i].voiceId,
  }));
  // 玩家演员：在线且报了 playerId 的这个小朋友。playerId 空（老客户端）时也允许无玩家开演（如纯观演的追逐）。
  const online = hub.membersIn(worldId).some((m) => m.playerId && m.playerId === playerId);
  if (playerId && online) {
    actors.push({ id: playerId, name: playerName(store, playerId), isPlayer: true });
  }
  if (actors.length === 0) {
    return { ok: false, reason: '现在场上没人，没法开演' };
  }
  return { ok: true, opts: { code: draft.code, actors } };
}

/** 玩家在剧本里的称呼：优先小名。档案没建出来就叫「小朋友」（与 stage_debut 同兜底）。 */
function playerName(store: WorldStore, playerId: string): string {
  const p = store.getPlayer(playerId);
  return p?.nickname || p?.name || '小朋友';
}
