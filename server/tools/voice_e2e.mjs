// 真实端到端：起本地 server（local 语音 + mock LLM）→ WS 走一遍边说边识别 → 校验 TTS 资产。
// 用法：node tools/voice_e2e.mjs
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const sherpa = require('sherpa-onnx-node');

const PORT = 8123;
const BASE = `http://127.0.0.1:${PORT}`;

const server = spawn('node', ['src/index.ts'], {
  env: { ...process.env, PORT: String(PORT), VOICE_PROVIDER: 'local', OPENROUTER_API_KEY: '' },
  stdio: ['ignore', 'pipe', 'pipe'],
});
server.stderr.on('data', (d) => process.stderr.write(d));
const ready = new Promise((res) => {
  server.stdout.on('data', (d) => {
    process.stdout.write(`[server] ${d}`);
    if (String(d).includes('8123')) res();
  });
});

try {
  const t0 = Date.now();
  await Promise.race([ready, new Promise((_, rej) => setTimeout(() => rej(new Error('server 启动超时')), 30000))]);
  console.log(`server 就绪（含模型加载）${Date.now() - t0}ms`);

  const world = await (await fetch(`${BASE}/worlds`, { method: 'POST' })).json();
  const characterId = world.characters[0].id;
  console.log(`world=${world.id} character=${characterId}`);

  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = (e) => rej(new Error(`ws error: ${e.message ?? e}`));
    setTimeout(() => rej(new Error('ws open 超时')), 5000);
  });
  console.log('ws 已连接');

  // 16k 中文测试音频 → PCM16 → 150ms 分片
  const wave = sherpa.readWave('models/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12/test_wavs/DEV_T0000000001.wav');
  const pcm = Buffer.from(Int16Array.from(wave.samples, (s) => Math.max(-32768, Math.min(32767, Math.round(s * 32767)))).buffer);
  const chunkBytes = 16000 * 0.15 * 2;

  const response = new Promise((res, rej) => {
    ws.onmessage = (m) => {
      const d = JSON.parse(m.data);
      console.log(`ws 收到 ${d.type}`);
      if (d.type === 'character_response') res(d);
      if (d.type === 'voice_failed') rej(new Error(d.reason));
    };
    ws.onclose = (e) => rej(new Error(`ws 意外关闭 code=${e.code}`));
    setTimeout(() => rej(new Error('character_response 超时(60s)')), 60000);
  });

  ws.send(JSON.stringify({ type: 'voice_start', worldId: world.id, characterId }));
  for (let off = 0; off < pcm.length; off += chunkBytes) {
    ws.send(JSON.stringify({ type: 'voice_chunk', audio: pcm.subarray(off, off + chunkBytes).toString('base64') }));
  }
  const tEnd = Date.now();
  ws.send(JSON.stringify({ type: 'voice_end' }));
  const resp = await response;
  const latency = Date.now() - tEnd;

  console.log(`转写：「${resp.transcript}」`);
  console.log(`回复：「${resp.replyText}」`);
  console.log(`voice_end → character_response 延迟 ${latency}ms（含 ASR 尾巴 + mock LLM + Kokoro 合成）`);

  const asset = await fetch(`${BASE}/assets/${resp.ttsAsset}`);
  const mime = asset.headers.get('content-type');
  const bytes = Buffer.from(await asset.arrayBuffer());
  console.log(`TTS 资产 mime=${mime} 大小=${bytes.length}B`);
  if (!/^audio\/L16;rate=24000$/.test(mime)) throw new Error(`mime 不符预期: ${mime}`);
  if (!resp.transcript || resp.transcript.length < 4) throw new Error('转写为空/过短');

  const i16 = new Int16Array(bytes.buffer, bytes.byteOffset, bytes.length / 2);
  sherpa.writeWave('/tmp/maliang_e2e_tts.wav', { samples: Float32Array.from(i16, (v) => v / 32768), sampleRate: 24000 });
  console.log('e2e 通过 ✅ 回复样音存 /tmp/maliang_e2e_tts.wav');
  ws.close();
} finally {
  server.kill();
}
