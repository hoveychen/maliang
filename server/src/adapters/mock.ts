import type { ServiceAdapters, ImageBlob } from './types.ts';
import type { CharacterSpec } from '../types.ts';

// 1x1 透明 PNG，作为生图占位。
const PNG_1x1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC';

function pngStub(): ImageBlob {
  return { bytes: Uint8Array.from(Buffer.from(PNG_1x1, 'base64')), mime: 'image/png' };
}

const ANIMALS = ['兔', '猫', '狗', '熊', '龙', '鸟', '鱼', '象', '鹿', '羊'];

function pickName(intent: string): string {
  for (const a of ANIMALS) if (intent.includes(a)) return `小${a}`;
  return '新朋友';
}

// 不适宜词（mock 审核用）。真实实现接专业审核服务。
const BAD_WORDS = /(暴力|血腥|恐怖|武器|杀|枪|刀)/;

/** mock 适配器：不调用任何外部服务，跑通整条编排闭环。 */
export function createMockAdapters(): ServiceAdapters {
  return {
    llm: {
      async designCharacter(intentText: string, _byFairy: boolean): Promise<CharacterSpec> {
        const name = pickName(intentText);
        return {
          name,
          personality: `一个友好、好奇的${name}，喜欢和小朋友玩。`,
          visualDescription: `Paper Mario 动漫风格的可爱${name}，圆润、色彩明亮、儿童友好，纯绿色背景`,
          voiceId: 'mock-voice-cn-child',
          scale: 1.0,
          abilities: ['move_to', 'deliver_message'],
        };
      },
      async respond(prompt: string): Promise<string> {
        return `（mock 回应）你说的是「${prompt}」对吗？`;
      },
    },
    image: {
      async generateSprite(_visualDescription: string): Promise<ImageBlob> {
        return pngStub();
      },
    },
    cutout: {
      async removeBackground(input: ImageBlob): Promise<ImageBlob> {
        return input; // mock：原样返回
      },
    },
    moderation: {
      async moderateText(text: string) {
        return BAD_WORDS.test(text)
          ? { allowed: false, reason: '文字含不适宜内容' }
          : { allowed: true };
      },
      async moderateImage(_input: ImageBlob) {
        return { allowed: true };
      },
    },
  };
}
