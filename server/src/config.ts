// 运行时配置。密钥从环境读取（node --env-file=.env），绝不写入源码。

export type VoiceProvider = 'auto' | 'local' | 'xfyun' | 'mock';

export interface Config {
  openrouterApiKey: string | undefined;
  llmModel: string;
  imageModel: string;
  moderationTextModel: string;
  xfyunAppId: string | undefined;
  xfyunApiKey: string | undefined;
  xfyunApiSecret: string | undefined;
  /** ASR/TTS 路由：auto=有本地模型用 local，否则有讯飞 key 用 xfyun，否则 mock。 */
  voiceProvider: VoiceProvider;
  /** 本地语音模型目录（scripts/fetch-voice-models.sh 拉取）。 */
  voiceModelsDir: string;
  /** local TTS 默认音色（Kokoro 音色名或 sid），角色 voiceId 不认识时回落。 */
  voiceTtsVoice: string;
}

export function loadConfig(): Config {
  return {
    openrouterApiKey: process.env.OPENROUTER_API_KEY,
    // 默认对话/意图模型：qwen3.6-flash（实测 ~1.3s 稳，中文童趣最足、自带安全意识）。
    // 旧默认 kimi-k2.6 实测 ~8s 且飘（默认开 reasoning），是语音延迟的主要变数。
    llmModel: process.env.OPENROUTER_LLM_MODEL ?? 'qwen/qwen3.6-flash',
    imageModel: process.env.OPENROUTER_IMAGE_MODEL ?? 'google/gemini-3.1-flash-image',
    moderationTextModel: process.env.OPENROUTER_MOD_TEXT_MODEL ?? 'moonshotai/kimi-k2.6',
    xfyunAppId: process.env.XFYUN_APP_ID,
    xfyunApiKey: process.env.XFYUN_API_KEY,
    xfyunApiSecret: process.env.XFYUN_API_SECRET,
    voiceProvider: parseVoiceProvider(process.env.VOICE_PROVIDER),
    voiceModelsDir: process.env.VOICE_MODELS_DIR ?? 'models',
    // zf_001：Kokoro v1.1-zh 温暖中文女声（talk-cli 默认同款）
    voiceTtsVoice: process.env.VOICE_TTS_VOICE ?? 'zf_001',
  };
}

function parseVoiceProvider(v: string | undefined): VoiceProvider {
  if (v === 'local' || v === 'xfyun' || v === 'mock' || v === 'auto') return v;
  if (v) console.warn(`未知 VOICE_PROVIDER=${v}，回落 auto`);
  return 'auto';
}

/** 有 key 才能用真实适配器；否则回落 mock。 */
export function hasOpenRouter(c: Config): boolean {
  return typeof c.openrouterApiKey === 'string' && c.openrouterApiKey.length > 0;
}

export function hasXfyun(c: Config): boolean {
  return !!(c.xfyunAppId && c.xfyunApiKey && c.xfyunApiSecret);
}
