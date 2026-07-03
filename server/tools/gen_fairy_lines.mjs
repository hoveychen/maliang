// 小仙子预制台词 TTS：读 assets/voice/fairy/lines.json，逐条 MiniMax 合成写 WAV。
// 幂等：已有 wav 跳过；--force 全量重生成。运行期游戏零 TTS 调用（纯播本地文件）。
// 用法：node --env-file=.env tools/gen_fairy_lines.mjs [--force]
import { readFile, writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { MinimaxTTSAdapter } from '../src/adapters/minimax.ts';

const here = dirname(fileURLToPath(import.meta.url));
const voiceDir = join(here, '../../assets/voice/fairy');
const force = process.argv.includes('--force');

const apiKey = process.env.MINIMAX_API_KEY;
if (!apiKey) {
  console.error('缺 MINIMAX_API_KEY（.env）');
  process.exit(1);
}

const spec = JSON.parse(await readFile(join(voiceDir, 'lines.json'), 'utf8'));
const tts = new MinimaxTTSAdapter({ apiKey, defaultVoice: spec.voice });

/** PCM16 mono → WAV 字节（44 字节头 + data）。 */
function wavBytes(pcm, rate) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.byteLength, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.byteLength, 40);
  return Buffer.concat([h, Buffer.from(pcm)]);
}

for (const line of spec.lines) {
  const file = join(voiceDir, `${line.id}.wav`);
  if (!force && await access(file).then(() => true, () => false)) {
    console.log(`skip ${line.id} (已存在)`);
    continue;
  }
  const audio = await tts.synthesize(line.text, spec.voice);
  const rate = Number(/rate=(\d+)/.exec(audio.mime)?.[1] ?? 24000);
  await writeFile(file, wavBytes(audio.bytes, rate));
  const durS = audio.bytes.byteLength / 2 / rate;
  console.log(`ok ${line.id}: ${durS.toFixed(1)}s 「${line.text}」`);
}
