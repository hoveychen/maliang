import type { ServiceAdapters, ASRAdapter, TTSAdapter } from './types.ts';
import { type Config, hasOpenRouter, hasXfyun } from '../config.ts';
import { createMockAdapters } from './mock.ts';
import { OpenRouterClient } from './openrouter_client.ts';
import { OpenRouterLLMAdapter } from './openrouter_llm.ts';
import { OpenRouterImageAdapter } from './openrouter_image.ts';
import { ChromaKeyCutoutAdapter } from './chroma_cutout.ts';
import { XfyunASRAdapter, XfyunTTSAdapter } from './xfyun.ts';
import { OpenRouterModerationAdapter } from './openrouter_moderation.ts';

/**
 * 按配置选择适配器（各服务独立）：
 * - 有 OpenRouter key → 真实 LLM/生图/抠图 + 内容审核（文字 LLM、图片视觉）；否则 mock。
 * - 有讯飞凭证 → 真实 ASR/TTS；否则 mock。
 */
export function createAdapters(config: Config): ServiceAdapters {
  const mock = createMockAdapters();

  let asr: ASRAdapter = mock.asr;
  let tts: TTSAdapter = mock.tts;
  if (hasXfyun(config)) {
    const creds = {
      appId: config.xfyunAppId as string,
      apiKey: config.xfyunApiKey as string,
      apiSecret: config.xfyunApiSecret as string,
    };
    asr = new XfyunASRAdapter(creds);
    tts = new XfyunTTSAdapter(creds);
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
    moderation: new OpenRouterModerationAdapter(client, config.moderationTextModel, config.moderationImageModel),
  };
}
