import type { ServiceAdapters, ASRAdapter, TTSAdapter } from './types.ts';
import {
  type Config,
  type TTSProvider,
  type VoiceProvider,
  hasMinimax,
  hasOpenRouter,
  hasXfyun,
} from '../config.ts';
import { createMockAdapters } from './mock.ts';
import { OpenRouterClient } from './openrouter_client.ts';
import { OpenRouterLLMAdapter } from './openrouter_llm.ts';
import { OpenRouterImageAdapter } from './openrouter_image.ts';
import { ChromaKeyCutoutAdapter } from './chroma_cutout.ts';
import { OpenRouterOrientationAdapter } from './openrouter_orientation.ts';
import { XfyunASRAdapter, XfyunTTSAdapter, type XfyunCreds } from './xfyun.ts';
import { LocalASRAdapter, LocalTTSAdapter, hasLocalVoiceModels } from './local.ts';
import { FallbackTTSAdapter, MinimaxTTSAdapter } from './minimax.ts';
import { OpenRouterModerationAdapter } from './openrouter_moderation.ts';

/** VOICE_ASR_PROVIDER=auto 的落点：有本地模型 local → 有讯飞 key xfyun → mock。 */
export function resolveAsrProvider(config: Config): Exclude<VoiceProvider, 'auto'> {
  if (config.voiceAsrProvider !== 'auto') return config.voiceAsrProvider;
  if (hasLocalVoiceModels(config.voiceModelsDir)) return 'local';
  if (hasXfyun(config)) return 'xfyun';
  return 'mock';
}

/** VOICE_TTS_PROVIDER=auto 的落点：有 MiniMax key minimax → 本地模型 local → 讯飞 → mock。 */
export function resolveTtsProvider(config: Config): Exclude<TTSProvider, 'auto'> {
  if (config.voiceTtsProvider !== 'auto') return config.voiceTtsProvider;
  if (hasMinimax(config)) return 'minimax';
  if (hasLocalVoiceModels(config.voiceModelsDir)) return 'local';
  if (hasXfyun(config)) return 'xfyun';
  return 'mock';
}

/**
 * 按配置选择适配器（各服务独立）：
 * - 有 OpenRouter key → 真实 LLM/生图/抠图 + 内容审核（文字 LLM、图片视觉）；否则 mock。
 * - ASR 由 VOICE_ASR_PROVIDER 路由（local=sherpa-onnx 进程内 / xfyun / mock）。
 * - TTS 由 VOICE_TTS_PROVIDER 路由（minimax 云端 / local Kokoro / xfyun / mock）；
 *   minimax + 本地模型同时在场时自动带 Kokoro 回落，网络故障不哑巴。
 */
export function createAdapters(config: Config): ServiceAdapters {
  const mock = createMockAdapters();

  const xfyunCreds = (): XfyunCreds => ({
    appId: config.xfyunAppId as string,
    apiKey: config.xfyunApiKey as string,
    apiSecret: config.xfyunApiSecret as string,
  });
  const requireLocalModels = (who: string): void => {
    if (!hasLocalVoiceModels(config.voiceModelsDir)) {
      throw new Error(`${who}=local 但模型缺失：请先运行 scripts/fetch-voice-models.sh ${config.voiceModelsDir}`);
    }
  };

  let asr: ASRAdapter = mock.asr;
  const asrProvider = resolveAsrProvider(config);
  if (asrProvider === 'local') {
    requireLocalModels('VOICE_ASR_PROVIDER');
    asr = new LocalASRAdapter({ modelsDir: config.voiceModelsDir });
  } else if (asrProvider === 'xfyun' && hasXfyun(config)) {
    asr = new XfyunASRAdapter(xfyunCreds());
  } else if (asrProvider === 'xfyun') {
    console.warn('VOICE_ASR_PROVIDER=xfyun 但讯飞凭证不全，ASR 回落 mock');
  }

  let tts: TTSAdapter = mock.tts;
  let ttsNote = '';
  const ttsProvider = resolveTtsProvider(config);
  if (ttsProvider === 'minimax' && hasMinimax(config)) {
    const minimax = new MinimaxTTSAdapter({
      apiKey: config.minimaxApiKey as string,
      model: config.minimaxTtsModel,
      defaultVoice: config.voiceTtsVoice ?? 'lovely_girl',
      speed: config.voiceTtsSpeed,
    });
    if (hasLocalVoiceModels(config.voiceModelsDir)) {
      tts = new FallbackTTSAdapter(minimax, new LocalTTSAdapter({ modelsDir: config.voiceModelsDir }));
      ttsNote = `（${config.minimaxTtsModel}，失败回落本地 Kokoro）`;
    } else {
      tts = minimax;
      ttsNote = `（${config.minimaxTtsModel}，无本地回落）`;
    }
  } else if (ttsProvider === 'minimax') {
    console.warn('VOICE_TTS_PROVIDER=minimax 但缺 MINIMAX_API_KEY，TTS 回落 mock');
  } else if (ttsProvider === 'local') {
    requireLocalModels('VOICE_TTS_PROVIDER');
    tts = new LocalTTSAdapter({ modelsDir: config.voiceModelsDir, defaultVoice: config.voiceTtsVoice ?? 'zf_001' });
  } else if (ttsProvider === 'xfyun' && hasXfyun(config)) {
    tts = new XfyunTTSAdapter(xfyunCreds());
  } else if (ttsProvider === 'xfyun') {
    console.warn('VOICE_TTS_PROVIDER=xfyun 但讯飞凭证不全，TTS 回落 mock');
  }

  console.log(`语音：ASR=${asrProvider} TTS=${ttsProvider}${ttsNote}`);

  if (!hasOpenRouter(config)) {
    return { ...mock, asr, tts };
  }
  const client = new OpenRouterClient(config.openrouterApiKey as string);
  // 生图单独用长超时客户端：实测 gemini 生图常态 60~75s，共享 25s 客户端必超时；
  // 语音意图等文本请求仍保持 25s（保护对话闭环延迟）。
  const imageClient = new OpenRouterClient(config.openrouterApiKey as string, 120000);
  // 朝向检测带图上传（base64 后 1-2MB），25s 客户端偶发不够，给 60s。
  const visionClient = new OpenRouterClient(config.openrouterApiKey as string, 60000);
  return {
    llm: new OpenRouterLLMAdapter(client, config.llmModel),
    image: new OpenRouterImageAdapter(imageClient, config.imageModel),
    cutout: new ChromaKeyCutoutAdapter(),
    orientation: new OpenRouterOrientationAdapter(visionClient, config.visionModel),
    asr,
    tts,
    moderation: new OpenRouterModerationAdapter(client, config.moderationTextModel),
  };
}
