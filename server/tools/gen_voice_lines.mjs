// 预制台词 TTS 批量合成：读 <目录>/lines.json，逐条 edge-tts（微软云，免费）合成 mp3，
// ffmpeg 转 PCM16 单声道写 WAV。voice 字段用 edge 音色名（如 zh-CN-XiaoxiaoNeural）；
// 音色由各目录 lines.json 的 voice 字段决定；点点（仙子/笔灵）与 intro 旁白当前用
// zh-CN-YunxiaNeural，与客户端运行期 edge_tts.gd 的映射一致（音色不跳变）。
// 幂等：已有 wav 跳过；--force 全量重生成。运行期游戏零 TTS 调用（纯播本地文件）。
// 用法：node tools/gen_voice_lines.mjs [目录=../assets/voice/fairy] [--force]
// 依赖：ffmpeg 在 PATH；ws 包（server 依赖树自带）。
import { readFile, writeFile, access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import WebSocket from 'ws';

const here = dirname(fileURLToPath(import.meta.url));
const dirArg = process.argv.slice(2).find((a) => !a.startsWith('--'));
const voiceDir = dirArg ? resolve(dirArg) : join(here, '../../assets/voice/fairy');
const force = process.argv.includes('--force');

const TRUSTED_TOKEN = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
const BASE = 'speech.platform.bing.com/consumer/speech/synthesize/readaloud';
const CHROMIUM = '143.0.3650.75';
const UA = `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${CHROMIUM.split('.')[0]}.0.0.0 Safari/537.36 Edg/${CHROMIUM.split('.')[0]}.0.0.0`;

function secMsGec() {
  let t = Math.floor(Date.now() / 1000) + 11644473600;
  t -= t % 300;
  return createHash('sha256').update(`${t * 10000000}${TRUSTED_TOKEN}`, 'ascii').digest('hex').toUpperCase();
}

function escapeXml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

/** edge-tts 合成一句 → 完整 mp3 Buffer（协议同 scripts/edge_tts.gd，见 docs/edge-tts-client-design.md）。 */
function edgeSynth(text, voice) {
  return new Promise((resolvePromise, reject) => {
    const url = `wss://${BASE}/edge/v1?TrustedClientToken=${TRUSTED_TOKEN}&ConnectionId=${randomUUID().replaceAll('-', '')}&Sec-MS-GEC=${secMsGec()}&Sec-MS-GEC-Version=1-${CHROMIUM}`;
    const ws = new WebSocket(url, {
      headers: {
        'User-Agent': UA,
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Cookie': `muid=${randomBytes(16).toString('hex').toUpperCase()};`,
      },
    });
    const chunks = [];
    const timer = setTimeout(() => { ws.terminate(); reject(new Error('edge-tts 10s 超时')); }, 10000);
    const jsDate = () => new Date().toUTCString();
    ws.on('open', () => {
      ws.send(`X-Timestamp:${jsDate()}\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n`
        + '{"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n');
      ws.send(`X-RequestId:${randomUUID().replaceAll('-', '')}\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:${jsDate()}Z\r\nPath:ssml\r\n\r\n`
        + `<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='${voice}'><prosody pitch='+0Hz' rate='+0%' volume='+0%'>${escapeXml(text)}</prosody></voice></speak>`);
    });
    ws.on('message', (data, isBinary) => {
      if (!isBinary) {
        if (data.toString().includes('Path:turn.end')) {
          clearTimeout(timer);
          ws.close();
          resolvePromise(Buffer.concat(chunks));
        }
        return;
      }
      const headerLen = data.readUInt16BE(0);
      if (data.subarray(2, 2 + headerLen).toString().includes('Path:audio')) {
        chunks.push(data.subarray(2 + headerLen));
      }
    });
    ws.on('error', (err) => { clearTimeout(timer); reject(err); });
  });
}

/** mp3 → PCM16 mono（rate Hz），走 ffmpeg 管道。 */
function mp3ToPcm(mp3, rate) {
  return new Promise((resolvePromise, reject) => {
    const ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0',
      '-f', 's16le', '-ar', String(rate), '-ac', '1', 'pipe:1']);
    const out = [];
    const err = [];
    ff.stdout.on('data', (d) => out.push(d));
    ff.stderr.on('data', (d) => err.push(d));
    ff.on('close', (code) => code === 0
      ? resolvePromise(Buffer.concat(out))
      : reject(new Error(`ffmpeg exit ${code}: ${Buffer.concat(err)}`)));
    ff.stdin.end(mp3);
  });
}

/** PCM16 mono → WAV 字节（44 字节头 + data）。 */
function wavBytes(pcm, rate) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + pcm.byteLength, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24); h.writeUInt32LE(rate * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(pcm.byteLength, 40);
  return Buffer.concat([h, Buffer.from(pcm)]);
}

const RATE = 24000;
const spec = JSON.parse(await readFile(join(voiceDir, 'lines.json'), 'utf8'));

for (const line of spec.lines) {
  const file = join(voiceDir, `${line.id}.wav`);
  if (!force && await access(file).then(() => true, () => false)) {
    console.log(`skip ${line.id} (已存在)`);
    continue;
  }
  // 实测连续快速建连 7~8 次会被微软 ECONNRESET 限流：逐条间隔 + 失败退避重试
  let mp3;
  for (let attempt = 1; ; attempt++) {
    try {
      // 每行可覆盖音色（story 音包多角色各用各声）；缺省用包级 voice（fairy/intro 等单声包不变）。
      mp3 = await edgeSynth(line.text, line.voice ?? spec.voice);
      break;
    } catch (err) {
      if (attempt >= 4) throw err;
      console.warn(`retry ${line.id} (#${attempt}): ${err.message}`);
      await new Promise((r) => setTimeout(r, 5000 * attempt));
    }
  }
  if (mp3.byteLength === 0) throw new Error(`${line.id}: edge-tts 返回空音频`);
  await new Promise((r) => setTimeout(r, 1500));
  const pcm = await mp3ToPcm(mp3, RATE);
  await writeFile(file, wavBytes(pcm, RATE));
  const durS = pcm.byteLength / 2 / RATE;
  console.log(`ok ${line.id}: ${durS.toFixed(1)}s 「${line.text}」`);
}
