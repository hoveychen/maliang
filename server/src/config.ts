// 运行时配置。密钥从环境读取（node --env-file=.env），绝不写入源码。

export type VoiceProvider = 'auto' | 'local' | 'mock';
export type TTSProvider = VoiceProvider | 'minimax';

export interface Config {
  openrouterApiKey: string | undefined;
  llmModel: string;
  /** 剧本生成（P5）专用强模型：硬 codegen 任务，不用常态便宜的对话模型。见 loadConfig 注释。 */
  screenplayModel: string;
  imageModel: string;
  /** idle 动画视频模型（Seedance）。透明立绘→绿幕 idle 循环 mp4。 */
  videoModel: string;
  /** 立绘朝向检测用的 vision 模型（看图回答朝向）。 */
  visionModel: string;
  moderationTextModel: string;
  minimaxApiKey: string | undefined;
  minimaxTtsModel: string;
  /** ASR/TTS 共同的基础路由；VOICE_ASR_PROVIDER / VOICE_TTS_PROVIDER 可分别覆盖。 */
  voiceProvider: VoiceProvider;
  /** ASR 路由：auto=有本地模型用 local → mock。 */
  voiceAsrProvider: VoiceProvider;
  /** TTS 路由：auto=有 MiniMax key 用 minimax → 本地模型 local → mock。 */
  voiceTtsProvider: TTSProvider;
  /** 本地语音模型目录（scripts/fetch-voice-models.sh 拉取）。 */
  voiceModelsDir: string;
  /** TTS 默认音色（按 provider 解释：Kokoro 音色名/sid 或 MiniMax voice_id）；未设则各 provider 自带默认。 */
  voiceTtsVoice: string | undefined;
  /** TTS 语速倍率（目前仅作用于 minimax）；未设则 adapter 默认 1.35（Boss 试听选定）。 */
  voiceTtsSpeed: number | undefined;
}

export function loadConfig(): Config {
  const base = parseVoiceProvider(process.env.VOICE_PROVIDER, 'VOICE_PROVIDER');
  return {
    openrouterApiKey: process.env.OPENROUTER_API_KEY,
    // 默认对话/意图模型：qwen3.6-flash（实测 ~1.3s 稳，中文童趣最足、自带安全意识）。
    // 旧默认 kimi-k2.6 实测 ~8s 且飘（默认开 reasoning），是语音延迟的主要变数。
    llmModel: process.env.OPENROUTER_LLM_MODEL ?? 'qwen/qwen3.6-flash',
    // 剧本生成（P5）：这是对着 typed SDK 的硬 codegen——弱模型会吐出过不了 typecheck / 误用原语 / 违反
    // 防腐纪律的脚本（老板明确要求「考虑模型的智能」）。故与对话模型（qwen3.6-flash）分离，选强的。
    // 2026-07-12 实测选型：首选 anthropic/claude-sonnet-5 但港区 403「not available in your region」不可用；
    // 改 moonshotai/kimi-k2.6（仓库已在用、港区可用的强 MoE），实测「踢球」「老鹰抓小鸡」两局均【一次过 typecheck、
    // 零诊断、复用现有原语无防腐违规、~3-5s】。它不在对话闭环、不影响语音延迟；过不了 typecheck 带错回喂重生成、
    // 仍不过口头兜底。OPENROUTER_SCREENPLAY_MODEL 可覆盖（如自建代理走 sonnet-5）。
    screenplayModel: process.env.OPENROUTER_SCREENPLAY_MODEL ?? 'moonshotai/kimi-k2.6',
    // 立绘生图：gemini-3.1-flash-lite-image（Nano Banana 2 Lite）为 2026-07-11 实测选型——
    // 对比 gemini-3.1-flash-image（旧默认）：$0.034 vs $0.068/张、3.1s vs 9.2s、风格遵循 7.7/8 vs 7.2/8，
    // 出图质量相当。两者出图尺寸行为一致（都主要吐 1408×768）。评测见 wiki maliang/image-model-eval。
    imageModel: process.env.OPENROUTER_IMAGE_MODEL ?? 'google/gemini-3.1-flash-lite-image',
    // idle 动画视频：seedance-1-5-pro 为 2026-07-08 实测选型（480p/4s $0.046/条，是能用里最便宜；
    // 首=尾帧做无缝闭合 RMSE 0.025 够用）。Google Veo 全系对幼儿角色 403 不可用；Seedance 2.0 更贵。
    videoModel: process.env.OPENROUTER_VIDEO_MODEL ?? 'bytedance/seedance-1-5-pro',
    // 立绘朝向检测（看图回答 LEFT/RIGHT/FRONT/BAD）。3.5-flash 为 2026-07-08 实测选型：
    // 3.1-flash 不是有效 OpenRouter ID（首批上线全 400 放行，喵小橘朝左漏网）；
    // 3.1-flash-lite 左右混淆（把明确朝左的旧小狐判 RIGHT）；3.5-flash 8 张样本全符合预期。
    visionModel: process.env.OPENROUTER_VISION_MODEL ?? 'google/gemini-3.5-flash',
    moderationTextModel: process.env.OPENROUTER_MOD_TEXT_MODEL ?? 'moonshotai/kimi-k2.6',
    minimaxApiKey: process.env.MINIMAX_API_KEY,
    // turbo 实测整句 1.0-1.9s、¥0.013/条；hd 音质更高、约 1.75 倍价
    minimaxTtsModel: process.env.MINIMAX_TTS_MODEL ?? 'speech-2.6-turbo',
    voiceProvider: base,
    voiceAsrProvider: parseVoiceProvider(process.env.VOICE_ASR_PROVIDER, 'VOICE_ASR_PROVIDER', base),
    voiceTtsProvider: parseTtsProvider(process.env.VOICE_TTS_PROVIDER, base),
    voiceModelsDir: process.env.VOICE_MODELS_DIR ?? 'models',
    voiceTtsVoice: process.env.VOICE_TTS_VOICE,
    voiceTtsSpeed: parseSpeed(process.env.VOICE_TTS_SPEED),
  };
}

function parseSpeed(v: string | undefined): number | undefined {
  if (!v) return undefined;
  const n = Number(v);
  if (Number.isFinite(n) && n >= 0.5 && n <= 2) return n;
  console.warn(`VOICE_TTS_SPEED=${v} 越界（0.5-2），忽略`);
  return undefined;
}

function parseVoiceProvider(v: string | undefined, name: string, fallback: VoiceProvider = 'auto'): VoiceProvider {
  if (v === 'local' || v === 'mock' || v === 'auto') return v;
  if (v) console.warn(`未知 ${name}=${v}，回落 ${fallback}`);
  return fallback;
}

function parseTtsProvider(v: string | undefined, fallback: VoiceProvider): TTSProvider {
  if (v === 'minimax') return v;
  return parseVoiceProvider(v, 'VOICE_TTS_PROVIDER', fallback);
}

/** 有 key 才能用真实适配器；否则回落 mock。 */
export function hasOpenRouter(c: Config): boolean {
  return typeof c.openrouterApiKey === 'string' && c.openrouterApiKey.length > 0;
}

export function hasMinimax(c: Config): boolean {
  return typeof c.minimaxApiKey === 'string' && c.minimaxApiKey.length > 0;
}
