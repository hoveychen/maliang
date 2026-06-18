import { test } from 'node:test';
import assert from 'node:assert/strict';
import { XfyunASRAdapter } from '../src/adapters/xfyun.ts';

// ASR 不该按 40ms/帧节流上传——我们手里已是录好的完整音频。
// 实测去节流后 ASR 3972ms→1005ms 且识别不变。
// 本测试：注入假 WebSocket，触发 onopen 后，所有音频帧应已同步发完（不靠 setTimeout 分批）。
test('ASR 全速上传：onopen 后所有帧同步发完（不节流）', async () => {
  const FRAME = 1280;
  const frames = 5;
  const pcm = new Uint8Array(FRAME * frames); // 5 帧音频

  const sends: string[] = [];
  let inst: any = null;
  class FakeWS {
    onopen: (() => void) | null = null;
    onmessage: ((m: any) => void) | null = null;
    onerror: (() => void) | null = null;
    constructor(_url: string) { inst = this; }
    send(s: string): void { sends.push(s); }
    close(): void {}
  }
  const origWS = (globalThis as any).WebSocket;
  (globalThis as any).WebSocket = FakeWS;
  try {
    const asr = new XfyunASRAdapter({ appId: 'a', apiKey: 'k', apiSecret: 's' });
    const p = asr.transcribe({ bytes: pcm, mime: 'audio/L16;rate=16000' });
    assert.ok(inst && inst.onopen, 'transcribe 应已创建 ws 并挂上 onopen');
    inst.onopen(); // 同步触发连接打开
    // 关键断言：onopen 同步返回后，5 帧音频 + 1 个结束帧都应已发出（共 6 条）。
    // 旧实现按 40ms 节流时此刻只发了第 1 帧（sends.length === 1）。
    assert.equal(sends.length, frames + 1, `应同步发完所有帧，实际 ${sends.length}`);
    // 收尾：喂一个 status:2 结果让 transcribe resolve，清掉内部 20s 超时计时器。
    inst.onmessage({ data: JSON.stringify({ code: 0, data: { status: 2 } }) });
    await p;
  } finally {
    (globalThis as any).WebSocket = origWS;
  }
});
