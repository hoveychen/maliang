import type { ServiceAdapters } from './types.ts';
import { type Config, hasOpenRouter } from '../config.ts';
import { createMockAdapters } from './mock.ts';
import { OpenRouterClient } from './openrouter_client.ts';
import { OpenRouterLLMAdapter } from './openrouter_llm.ts';
import { OpenRouterImageAdapter } from './openrouter_image.ts';
import { ChromaKeyCutoutAdapter } from './chroma_cutout.ts';

/**
 * 按配置选择适配器：有 OpenRouter key → 真实（LLM+生图+抠图）；否则全 mock。
 * 内容审核暂用 mock 占位（真实审核服务在 M4 接入）。
 */
export function createAdapters(config: Config): ServiceAdapters {
  if (!hasOpenRouter(config)) {
    return createMockAdapters();
  }
  const client = new OpenRouterClient(config.openrouterApiKey as string);
  const mock = createMockAdapters();
  return {
    llm: new OpenRouterLLMAdapter(client, config.llmModel),
    image: new OpenRouterImageAdapter(client, config.imageModel),
    cutout: new ChromaKeyCutoutAdapter(),
    asr: mock.asr, // TODO(M2-real): 接讯飞 ASR
    tts: mock.tts, // TODO(M2-real): 接讯飞 TTS
    moderation: mock.moderation, // TODO(M4): 真实文字+图片审核服务
  };
}
