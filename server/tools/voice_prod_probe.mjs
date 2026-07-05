// 生产语音链路实测：wss 走一遍 voice_start/chunk/end（真实中文音频）+ voice_transcript 路径，量延迟。
// 用法：node tools/voice_prod_probe.mjs [wss://maliang-api.muveeai.com]
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sherpa = require('sherpa-onnx-node');
const BASE = process.argv[2] ?? 'https://maliang-api.muveeai.com';
const WS = BASE.replace(/^http/, 'ws') + '/ws';

const world = await (await fetch(`${BASE}/worlds`, { method: 'POST' })).json();
const characterId = world.characters[0].id;
console.log(`world=${world.id} character=${world.characters[0].name}`);

const ws = new WebSocket(WS);
await new Promise((res, rej) => {
  ws.onopen = res;
  ws.onerror = (e) => rej(new Error(`ws error: ${e.message ?? e}`));
  setTimeout(() => rej(new Error('ws open 超时')), 10000);
});

const wave = sherpa.readWave('models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12/test_wavs/DEV_T0000000001.wav');
const pcm = Buffer.from(Int16Array.from(wave.samples, (s) => Math.max(-32768, Math.min(32767, Math.round(s * 32767)))).buffer);

// 流式 TTS 时 character_response.ttsAsset 为空（音频走 tts_chunk 分片），
// 真实资产 hash 在 tts_end 里——等到 tts_end 再返回，避免拿空 hash 去 GET /assets/ 误报。
function waitResponse(timeoutMs = 40000) {
  return new Promise((res, rej) => {
    let resp = null;
    ws.onmessage = (m) => {
      const d = JSON.parse(m.data);
      if (d.type === 'character_response') {
        resp = d;
        if (!d.ttsStreaming) res(d); // 非流式：ttsAsset 已在响应里，不会再有 tts_end
      }
      if (d.type === 'tts_end' && resp) res({ ...resp, ttsAsset: d.ttsAsset });
      if (d.type === 'voice_failed') rej(new Error(d.reason));
    };
    setTimeout(() => rej(new Error('response 超时')), timeoutMs);
  });
}

// 1) 流式音频路径（服务端 ASR）
ws.send(JSON.stringify({ type: 'voice_start', worldId: world.id, characterId }));
for (let off = 0; off < pcm.length; off += 4800) {
  ws.send(JSON.stringify({ type: 'voice_chunk', audio: pcm.subarray(off, off + 4800).toString('base64') }));
}
let t0 = Date.now();
ws.send(JSON.stringify({ type: 'voice_end' }));
let resp = await waitResponse();
console.log(`[音频路径] voice_end→回复 ${Date.now() - t0}ms 转写「${resp.transcript}」回复「${resp.replyText.slice(0, 30)}…」`);

const asset = await fetch(`${BASE}/assets/${resp.ttsAsset}`);
console.log(`[TTS 资产] mime=${asset.headers.get('content-type')} 大小=${(await asset.arrayBuffer()).byteLength}B`);

// 2) 端侧转写路径（voice_transcript 直送）
t0 = Date.now();
ws.send(JSON.stringify({ type: 'voice_transcript', worldId: world.id, characterId, transcript: '你好呀，我们一起去种向日葵吧' }));
resp = await waitResponse();
console.log(`[转写路径] voice_transcript→回复 ${Date.now() - t0}ms 回复「${resp.replyText.slice(0, 30)}…」`);

ws.close();
process.exit(0);
