import { createHash } from 'node:crypto';
import type { WorldStore } from './persistence.ts';

/**
 * 角色音色目录（edge-tts，客户端直连微软合成，见 docs/edge-tts-client-design.md）。
 * id 直接用 edge 音色名存进 character.voiceId——客户端 edge_tts.gd 对 zh- 前缀直通，
 * 服务端降级 TTS（MiniMax/Kokoro）遇到不认识的 id 自动回落各自默认音色，链路不炸。
 * desc/tags 为中文气质描述：注入 designCharacter 的 prompt 供 LLM 按角色性格选声，
 * 也供管理台/预设角色人工挑选参考。
 */
export interface VoiceInfo {
  id: string;
  gender: '女' | '男';
  /** 一句话气质描述（LLM 选声的主要依据）。 */
  desc: string;
  /** 适合什么样的角色。 */
  tags: string[];
  /** 主力池：legacy 角色回填哈希只落主力池（方言/台湾腔只让 LLM 主动选，不随机分配）。 */
  main?: boolean;
}

export const VOICE_CATALOG: VoiceInfo[] = [
  { id: 'zh-CN-XiaoyiNeural', gender: '女', desc: '活泼灵动的少女音，元气满满', tags: ['小仙女', '俏皮女孩', '小精灵'], main: true },
  { id: 'zh-CN-XiaoxiaoNeural', gender: '女', desc: '温暖亲切的大姐姐音，柔和贴心', tags: ['温柔角色', '姐姐', '治愈系'], main: true },
  { id: 'zh-CN-YunxiaNeural', gender: '男', desc: '奶声奶气的小男孩音，天真可爱', tags: ['幼崽', '小动物', '弟弟'], main: true },
  { id: 'zh-CN-YunxiNeural', gender: '男', desc: '阳光开朗的少年音，朝气十足', tags: ['探险家', '哥哥', '运动健将'], main: true },
  { id: 'zh-CN-YunjianNeural', gender: '男', desc: '浑厚有力的大叔音，威武豪迈', tags: ['大型动物', '勇士', '爸爸型'] },
  { id: 'zh-CN-YunyangNeural', gender: '男', desc: '沉稳可靠的播音男声，一本正经', tags: ['博士', '村长', '老师'] },
  { id: 'zh-CN-liaoning-XiaobeiNeural', gender: '女', desc: '幽默逗趣的东北腔，自带喜感', tags: ['搞笑担当', '东北方言彩蛋'] },
  { id: 'zh-CN-shaanxi-XiaoniNeural', gender: '女', desc: '爽朗明快的陕西腔，风风火火', tags: ['豪爽角色', '陕西方言彩蛋'] },
  { id: 'zh-TW-HsiaoChenNeural', gender: '女', desc: '软糯甜美的台湾腔女声，温温柔柔', tags: ['甜美角色', '慢性子'] },
  { id: 'zh-TW-HsiaoYuNeural', gender: '女', desc: '清亮悦耳的台湾腔女声，乖巧文静', tags: ['文静女孩', '小淑女'] },
  { id: 'zh-TW-YunJheNeural', gender: '男', desc: '斯文温和的台湾腔男声，书卷气', tags: ['书生', '文静角色', '慢性子'] },
];

/** 仙子固定音色（与预制台词 lines.json、客户端 legacy 映射一致，不参与随机分配）。 */
export const FAIRY_VOICE = 'zh-CN-XiaoyiNeural';

const IDS = new Set(VOICE_CATALOG.map((v) => v.id));
const MAIN_POOL = VOICE_CATALOG.filter((v) => v.main).map((v) => v.id);

export function isKnownVoice(id: string): boolean {
  return IDS.has(id);
}

/** 稳定哈希落主力池：同一 characterId 永远同声（回填/LLM 输出非法时的兜底）。 */
export function fallbackVoice(characterId: string): string {
  const h = createHash('sha1').update(characterId).digest();
  return MAIN_POOL[h.readUInt32BE(0) % MAIN_POOL.length];
}

/**
 * 玩家音色池（玩家间对话的 ASR 文本中继在对端 TTS 出声用，见 docs/player-interaction-design.md）。
 * 按 profile 性别分池、playerId 稳定哈希落一款：同一玩家在所有端永远同声。
 * 池子只收儿童/少年向音色——出声的是「小朋友的角色」，不能是大叔播音腔。
 */
const PLAYER_VOICES: Record<string, string[]> = {
  boy: ['zh-CN-YunxiaNeural', 'zh-CN-YunxiNeural'],
  girl: ['zh-CN-XiaoyiNeural', 'zh-CN-XiaoxiaoNeural'],
};
const PLAYER_VOICES_ANY = [...PLAYER_VOICES.boy, ...PLAYER_VOICES.girl];

/** 玩家 id → 稳定音色（gender 缺省/未知时落全池）。 */
export function voiceForPlayer(playerId: string, gender?: string): string {
  const pool = PLAYER_VOICES[gender ?? ''] ?? PLAYER_VOICES_ANY;
  const h = createHash('sha1').update(playerId).digest();
  return pool[h.readUInt32BE(0) % pool.length];
}

/** 目录渲染成 prompt 行（注入 designCharacter 的 system）。 */
export function voicePromptLines(): string {
  return VOICE_CATALOG
    .map((v) => `- ${v.id}（${v.gender}）：${v.desc}，适合${v.tags.join('、')}`)
    .join('\n');
}

/**
 * 存量回填：voiceId 不在目录里的角色（上线前的 cn-child-default / mock-voice-* / Kokoro/MiniMax 旧名）
 * 按 id 稳定哈希落主力池；仙子固定 FAIRY_VOICE。幂等，返回改写条数。
 * 服务启动跑一次（buildServer 的 backfillOnBoot，同 idle 动画回填）。
 */
export function backfillVoices(store: WorldStore): number {
  let changed = 0;
  for (const world of store.listWorlds()) {
    for (const c of store.listCharacters(world.id)) {
      if (isKnownVoice(c.voiceId)) continue;
      c.voiceId = c.isFairy ? FAIRY_VOICE : fallbackVoice(c.id);
      store.saveCharacter(c);
      changed += 1;
    }
  }
  return changed;
}
