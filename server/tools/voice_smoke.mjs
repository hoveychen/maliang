// 本地语音冒烟：真模型跑一遍 TTS/ASR，打印延迟。用法：node tools/voice_smoke.mjs
import { LocalTTSAdapter, LocalASRAdapter } from '../src/adapters/local.ts';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sherpa = require('sherpa-onnx-node');

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

// --- ASR ---
t0 = Date.now();
const asr = new LocalASRAdapter(opts);
console.log(`ASR 模型加载 ${Date.now() - t0}ms`);

const wave = sherpa.readWave('models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12/test_wavs/DEV_T0000000000.wav');
// 16k float → PCM16 字节，模拟客户端 150ms 分片 feed
const pcm = new Uint8Array(Int16Array.from(wave.samples, (s) => Math.max(-32768, Math.min(32767, Math.round(s * 32767)))).buffer);
const chunkBytes = 16000 * 0.15 * 2;
const stream = asr.openStream();
t0 = Date.now();
let feedTotal = 0;
for (let off = 0; off < pcm.length; off += chunkBytes) {
  const f0 = Date.now();
  stream.feed(pcm.subarray(off, off + chunkBytes));
  feedTotal += Date.now() - f0;
}
const t1 = Date.now();
const result = await stream.finish();
console.log(`ASR 转写：「${result}」`);
console.log(`feed 总耗时 ${feedTotal}ms（音频 ${(pcm.length / 2 / 16000).toFixed(2)}s），finish 尾巴 ${Date.now() - t1}ms`);
