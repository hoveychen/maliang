import type { ServiceAdapters, ImageBlob, AudioBlob } from './types.ts';
import type { CharacterSpec, IntentContext, IntentResult, MemoryExtractionContext } from '../types.ts';
import type { SdfPropSpec } from '../sdf_prop.ts';

// 1x1 透明 PNG，作为生图占位。（须是合法 PNG：Godot 客户端会真解码，CRC 错会拒收；
// 旧值 IDAT CRC 损坏，Node 侧从未校验所以一直没暴露）
const PNG_1x1 =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4AWMAAQAABQABNtCI3QAAAABJRU5ErkJggg==';

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

// 口语里的「去/到/走」当成移动指令（mock 意图路由用）。
const GO_WORDS = /(去|到|走去|过去)/;

function audioStub(): AudioBlob {
  // 极小的占位音频（mock TTS）。真实 TTS 由讯飞产出。
  return { bytes: Uint8Array.from([0x52, 0x49, 0x46, 0x46]), mime: 'audio/wav' };
}

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
      async designSdfProp(intentText: string): Promise<SdfPropSpec> {
        // mock：按关键词确定性挑运动方式，结构固定（真实实现由 LLM 自由拼形状）
        const hop = /(跳|蹦|兔)/.test(intentText);
        const fly = /(飞|翅|蝶|鸟)/.test(intentText);
        const locomotion: SdfPropSpec['locomotion'] = fly
          ? { type: 'flyer', hover_h: 1.4, wing_len: 0.4, rate: 3, speed: 1 }
          : hop
            ? { type: 'hopper', hop_h: 0.45, rate: 1.5, speed: 0.9 }
            : { type: 'walker', legs: 4, leg_r: 0.1, hip_h: 0.6, stance: [0.45, 0.4], speed: 0.8 };
        return {
          name: 'mock_prop',
          palette: ['#e8b04b', '#f4ead4'],
          blend: 0.26,
          outline: 0.04,
          parts: [
            { shape: 'box', pos: [0, 0.95, 0], size: [0.9, 0.7, 0.8], color: 1 },
            { shape: 'sphere', pos: [0, 1.5, 0.2], r: 0.22, color: 0, blend: 0.15 },
          ],
          locomotion,
          ropes: [{ pos: [0, 1.2, -0.45], segments: 3, r: 0.06, len: 0.2, color: 0 }],
        };
      },
      async routeIntent(transcript: string, _ctx: IntentContext): Promise<IntentResult> {
        if (GO_WORDS.test(transcript)) {
          return {
            kind: 'command',
            replyText: '好的，我这就去！',
            behaviorScript: {
              commands: [{ type: 'move_to', params: { location_name: transcript } }],
              loop: false,
            },
            emotion: 'wave',
          };
        }
        return { kind: 'chat', replyText: `（mock 回应）你说的是「${transcript}」对吗？`, emotion: 'happy' };
      },
      async extractMemory(ctx: MemoryExtractionContext): Promise<string[]> {
        // mock：确定性地从「我叫X」「我喜欢X」抽要点，去重后返回（真实接 LLM 自由判断）
        const facts: string[] = [];
        const nameM = /我叫([^\s，。!！?？]{1,8})/.exec(ctx.transcript);
        if (nameM) facts.push(`小朋友叫${nameM[1]}`);
        const likeM = /我喜欢([^\s，。!！?？]{1,12})/.exec(ctx.transcript);
        if (likeM) facts.push(`小朋友喜欢${likeM[1]}`);
        return facts.filter((f) => !ctx.existingMemory.includes(f));
      },
      async extractProfile(transcript: string): Promise<{ name: string; nickname: string }> {
        // mock：确定性从「我叫X / 我是X」提取；真实接 LLM 自由理解（含称呼、小名）
        const m = /我(?:叫|是)([^\s，。!！?？]{1,8})/.exec(transcript);
        const name = m ? m[1] : '';
        return { name, nickname: name };
      },
      async respond(prompt: string): Promise<string> {
        return `（mock 回应）你说的是「${prompt}」对吗？`;
      },
    },
    asr: {
      async transcribe(_audio: AudioBlob): Promise<string> {
        return '你好呀'; // mock：固定转写；真实接讯飞
      },
      openStream() {
        return {
          feed(_chunk: Uint8Array): void { /* mock：忽略分片 */ },
          async finish(): Promise<string> { return '你好呀'; },
        };
      },
    },
    tts: {
      async synthesize(_text: string, _voiceId: string): Promise<AudioBlob> {
        return audioStub();
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
    },
  };
}
