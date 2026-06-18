import { test } from 'node:test';
import assert from 'node:assert/strict';
import { XfyunASRAdapter } from '../src/adapters/xfyun.ts';

// 边说边识别：openStream 应在连接打开后实时发帧（首帧 status0 带 business、续帧 status1），
// 连接前 feed 的分片要入队补发，finish 发 status2，讯飞回 status2 结果时 resolve 转写。
test('openStream 流式会话状态机', async () => {
  const sends: any[] = [];
  let inst: any = null;
  class FakeWS {
    onopen: (() => void) | null = null;
    onmessage: ((m: any) => void) | null = null;
    onerror: (() => void) | null = null;
    constructor(_url: string) { inst = this; }
    send(s: string): void { sends.push(JSON.parse(s)); }
    close(): void {}
  }
  const orig = (globalThis as any).WebSocket;
  (globalThis as any).WebSocket = FakeWS;
  try {
    const asr = new XfyunASRAdapter({ appId: 'a', apiKey: 'k', apiSecret: 's' });
    const stream = asr.openStream();

    stream.feed(new Uint8Array(1280)); // 连接前 feed → 入队，不发
    assert.equal(sends.length, 0, '未连接时分片应入队、不发');

    inst.onopen(); // 连接打开 → 补发积压
    assert.equal(sends.length, 1, 'onopen 后补发队列');
    assert.equal(sends[0].data.status, 0, '首帧 status0');
    assert.ok(sends[0].business?.language === 'zh_cn', '首帧带 business 配置');

    stream.feed(new Uint8Array(1280)); // 已连 → 立即发
    assert.equal(sends.length, 2);
    assert.equal(sends[1].data.status, 1, '续帧 status1');

    const p = stream.finish();
    assert.equal(sends[sends.length - 1].data.status, 2, 'finish 发 status2');

    inst.onmessage({ data: JSON.stringify({ code: 0, data: { result: { ws: [{ cw: [{ w: '你好' }] }] }, status: 1 } }) });
    inst.onmessage({ data: JSON.stringify({ code: 0, data: { status: 2 } }) });
    assert.equal(await p, '你好', 'status2 结果时 resolve 累计转写');
  } finally {
    (globalThis as any).WebSocket = orig;
  }
});

test('openStream：finish 在连接打开前调用，onopen 后补发结束帧', async () => {
  const sends: any[] = [];
  let inst: any = null;
  class FakeWS {
    onopen: (() => void) | null = null;
    onmessage: ((m: any) => void) | null = null;
    onerror: (() => void) | null = null;
    constructor(_url: string) { inst = this; }
    send(s: string): void { sends.push(JSON.parse(s)); }
    close(): void {}
  }
  const orig = (globalThis as any).WebSocket;
  (globalThis as any).WebSocket = FakeWS;
  try {
    const stream = new XfyunASRAdapter({ appId: 'a', apiKey: 'k', apiSecret: 's' }).openStream();
    stream.feed(new Uint8Array(1280));
    const p = stream.finish(); // 连接还没开
    assert.equal(sends.length, 0, '未连接时什么都没发');
    inst.onopen(); // 补发：分片 + 结束帧
    assert.deepEqual(sends.map((s) => s.data.status), [0, 2], 'onopen 后补发 [status0, status2]');
    inst.onmessage({ data: JSON.stringify({ code: 0, data: { result: { ws: [{ cw: [{ w: '嗨' }] }] }, status: 2 } }) });
    assert.equal(await p, '嗨');
  } finally {
    (globalThis as any).WebSocket = orig;
  }
});
