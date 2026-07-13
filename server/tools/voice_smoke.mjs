// 本地语音冒烟：真模型跑一遍 TTS，打印延迟。用法：node tools/voice_smoke.mjs
// （识别不在服务端：ASR 一律客户端端侧，见 test/macos_asr_recognize.gd）
import { LocalTTSAdapter } from '../src/adapters/local.ts';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sherpa = require('sherpa-onnx-node'); // 只为把样音写成 wav 给人耳验收

const opts = { modelsDir: 'models', defaultVoice: 'zf_001' };

// --- TTS ---
let t0 = Date.now();
const tts = new LocalTTSAdapter(opts);
console.log(`TTS 模型加载 ${Date.now() - t0}ms`);

const text = '你好呀小朋友！我是小兔子，今天想在花园里种一朵向日葵，2025年的夏天一定会很棒！';
t0 = Date.now();
const audio = await tts.synthesize(text, 'cn-child-default');
const synthMs = Date.now() - t0;
const rate = Number(/rate=(\d+)/.exec(audio.mime)[1]);
const durS = audio.bytes.byteLength / 2 / rate;
console.log(`TTS 合成 ${synthMs}ms，音频 ${durS.toFixed(2)}s @${rate}Hz，RTF=${(synthMs / 1000 / durS).toFixed(3)}，mime=${audio.mime}`);

// 存出来给人耳验收
const i16 = new Int16Array(audio.bytes.buffer, audio.bytes.byteOffset, audio.bytes.byteLength / 2);
const f32 = Float32Array.from(i16, (v) => v / 32768);
sherpa.writeWave('/tmp/maliang_tts_smoke.wav', { samples: f32, sampleRate: rate });
console.log('样音已存 /tmp/maliang_tts_smoke.wav');
