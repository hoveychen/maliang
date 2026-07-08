// 运行时配置。密钥从环境读取（node --env-file=.env），绝不写入源码。

export type VoiceProvider = 'auto' | 'local' | 'xfyun' | 'mock';
export type TTSProvider = VoiceProvider | 'minimax';

export interface Config {
  openrouterApiKey: string | undefined;
  llmModel: string;
  imageModel: string;
  /** idle 动画视频模型（Seedance）。透明立绘→绿幕 idle 循环 mp4。 */
  videoModel: string;
  /** 立绘朝向检测用的 vision 模型（看图回答朝向）。 */
  visionModel: string;
  moderationTextModel: string;
  xfyunAppId: string | undefined;
  xfyunApiKey: string | undefined;
  xfyunApiSecret: string | undefined;
  minimaxApiKey: string | undefined;
  minimaxTtsModel: string;
  /** ASR/TTS 共同的基础路由；VOICE_ASR_PROVIDER / VOICE_TTS_PROVIDER 可分别覆盖。 */
  voiceProvider: VoiceProvider;
  /** ASR 路由：auto=有本地模型用 local → 有讯飞 key 用 xfyun → mock。 */
  voiceAsrProvider: VoiceProvider;
  /** TTS 路由：auto=有 MiniMax key 用 minimax → 本地模型 local → 讯飞 → mock。 */
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
    imageModel: process.env.OPENROUTER_IMAGE_MODEL ?? 'google/gemini-3.1-flash-image',
    // idle 动画视频：seedance-1-5-pro 为 2026-07-08 实测选型（480p/4s $0.046/条，是能用里最便宜；
    // 首=尾帧做无缝闭合 RMSE 0.025 够用）。Google Veo 全系对幼儿角色 403 不可用；Seedance 2.0 更贵。
    videoModel: process.env.OPENROUTER_VIDEO_MODEL ?? 'bytedance/seedance-1-5-pro',
    // 立绘朝向检测（看图回答 LEFT/RIGHT/FRONT/BAD）。3.5-flash 为 2026-07-08 实测选型：
    // 3.1-flash 不是有效 OpenRouter ID（首批上线全 400 放行，喵小橘朝左漏网）；
    // 3.1-flash-lite 左右混淆（把明确朝左的旧小狐判 RIGHT）；3.5-flash 8 张样本全符合预期。
    visionModel: process.env.OPENROUTER_VISION_MODEL ?? 'google/gemini-3.5-flash',
    moderationTextModel: process.env.OPENROUTER_MOD_TEXT_MODEL ?? 'moonshotai/kimi-k2.6',
    xfyunAppId: process.env.XFYUN_APP_ID,
    xfyunApiKey: process.env.XFYUN_API_KEY,
    xfyunApiSecret: process.env.XFYUN_API_SECRET,
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
  if (v === 'local' || v === 'xfyun' || v === 'mock' || v === 'auto') return v;
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

export function hasXfyun(c: Config): boolean {
  return !!(c.xfyunAppId && c.xfyunApiKey && c.xfyunApiSecret);
}

export function hasMinimax(c: Config): boolean {
  return typeof c.minimaxApiKey === 'string' && c.minimaxApiKey.length > 0;
}
