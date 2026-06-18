// 运行时配置。密钥从环境读取（node --env-file=.env），绝不写入源码。

export interface Config {
  openrouterApiKey: string | undefined;
  llmModel: string;
  imageModel: string;
  xfyunAppId: string | undefined;
  xfyunApiKey: string | undefined;
  xfyunApiSecret: string | undefined;
}

export function loadConfig(): Config {
  return {
    openrouterApiKey: process.env.OPENROUTER_API_KEY,
    llmModel: process.env.OPENROUTER_LLM_MODEL ?? 'moonshotai/kimi-k2.6',
    imageModel: process.env.OPENROUTER_IMAGE_MODEL ?? 'google/gemini-3.1-flash-image',
    xfyunAppId: process.env.XFYUN_APP_ID,
    xfyunApiKey: process.env.XFYUN_API_KEY,
    xfyunApiSecret: process.env.XFYUN_API_SECRET,
  };
}

/** 有 key 才能用真实适配器；否则回落 mock。 */
export function hasOpenRouter(c: Config): boolean {
  return typeof c.openrouterApiKey === 'string' && c.openrouterApiKey.length > 0;
}

export function hasXfyun(c: Config): boolean {
  return !!(c.xfyunAppId && c.xfyunApiKey && c.xfyunApiSecret);
}
