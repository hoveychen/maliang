import type { ServiceAdapters, ASRAdapter, TTSAdapter } from './types.ts';
import { type Config, type VoiceProvider, hasOpenRouter, hasXfyun } from '../config.ts';
import { createMockAdapters } from './mock.ts';
import { OpenRouterClient } from './openrouter_client.ts';
import { OpenRouterLLMAdapter } from './openrouter_llm.ts';
import { OpenRouterImageAdapter } from './openrouter_image.ts';
import { ChromaKeyCutoutAdapter } from './chroma_cutout.ts';
import { XfyunASRAdapter, XfyunTTSAdapter } from './xfyun.ts';
import { LocalASRAdapter, LocalTTSAdapter, hasLocalVoiceModels } from './local.ts';
import { OpenRouterModerationAdapter } from './openrouter_moderation.ts';

/** VOICE_PROVIDER=auto 的落点：有本地模型用 local，否则有讯飞 key 用 xfyun，否则 mock。 */
export function resolveVoiceProvider(config: Config): Exclude<VoiceProvider, 'auto'> {
  if (config.voiceProvider !== 'auto') return config.voiceProvider;
  if (hasLocalVoiceModels(config.voiceModelsDir)) return 'local';
  if (hasXfyun(config)) return 'xfyun';
  return 'mock';
}

/**
 * 按配置选择适配器（各服务独立）：
 * - 有 OpenRouter key → 真实 LLM/生图/抠图 + 内容审核（文字 LLM、图片视觉）；否则 mock。
 * - ASR/TTS 由 VOICE_PROVIDER 路由：local（sherpa-onnx 本地推理）/ xfyun / mock / auto。
 */
export function createAdapters(config: Config): ServiceAdapters {
  const mock = createMockAdapters();

  let asr: ASRAdapter = mock.asr;
  let tts: TTSAdapter = mock.tts;
  const voice = resolveVoiceProvider(config);
  if (voice === 'local') {
    if (!hasLocalVoiceModels(config.voiceModelsDir)) {
      throw new Error(
        `VOICE_PROVIDER=local 但模型缺失：请先运行 scripts/fetch-voice-models.sh ${config.voiceModelsDir}`,
      );
    }
    const opts = { modelsDir: config.voiceModelsDir, defaultVoice: config.voiceTtsVoice };
    asr = new LocalASRAdapter(opts);
    tts = new LocalTTSAdapter(opts);
    console.log(`语音：local（sherpa-onnx，模型目录 ${config.voiceModelsDir}，默认音色 ${config.voiceTtsVoice}）`);
  } else if (voice === 'xfyun' && hasXfyun(config)) {
    const creds = {
      appId: config.xfyunAppId as string,
      apiKey: config.xfyunApiKey as string,
      apiSecret: config.xfyunApiSecret as string,
    };
    asr = new XfyunASRAdapter(creds);
    tts = new XfyunTTSAdapter(creds);
    console.log('语音：xfyun');
  } else if (voice === 'xfyun') {
    console.warn('VOICE_PROVIDER=xfyun 但讯飞凭证不全，语音回落 mock');
  }

  if (!hasOpenRouter(config)) {
    return { ...mock, asr, tts };
  }
  const client = new OpenRouterClient(config.openrouterApiKey as string);
  return {
    llm: new OpenRouterLLMAdapter(client, config.llmModel),
    image: new OpenRouterImageAdapter(client, config.imageModel),
    cutout: new ChromaKeyCutoutAdapter(),
    asr,
    tts,
    moderation: new OpenRouterModerationAdapter(client, config.moderationTextModel),
  };
}
