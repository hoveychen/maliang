import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { TcpClient } from "../src/tcp_client.ts";

// 起一个 mock 命令口：逐行收 JSON，按 op 回一行 JSON（模仿 debug_cmd_server）。
function mockServer(): Promise<{ port: number; close: () => void }> {
  return new Promise((resolve) => {
    const srv = net.createServer((sock) => {
      let buf = "";
      sock.setEncoding("utf8");
      sock.on("data", (d: string) => {
        buf += d;
        let nl = buf.indexOf("\n");
        while (nl >= 0) {
          const line = buf.slice(0, nl);
          buf = buf.slice(nl + 1);
          nl = buf.indexOf("\n");
          if (!line.trim()) continue;
          const cmd = JSON.parse(line);
          sock.write(JSON.stringify({ ok: true, op: cmd.op, echo: cmd }) + "\n");
        }
      });
    });
    srv.listen(0, "127.0.0.1", () => {
      const addr = srv.address() as net.AddressInfo;
      resolve({ port: addr.port, close: () => srv.close() });
    });
  });
}

test("connect + send 解析回一行 JSON", async () => {
  const s = await mockServer();
  const c = new TcpClient("127.0.0.1", s.port);
  await c.connect();
  const r = await c.send({ op: "state" });
  assert.equal(r.ok, true);
  assert.equal(r.op, "state");
  c.close();
  s.close();
});

test("多发按序 FIFO 匹配应答（不错位）", async () => {
  const s = await mockServer();
  const c = new TcpClient("127.0.0.1", s.port);
  await c.connect();
  const [a, b, d] = await Promise.all([
    c.send({ op: "one" }),
    c.send({ op: "two" }),
    c.send({ op: "three" }),
  ]);
  assert.equal((a.echo as Record<string, unknown>).op, "one");
  assert.equal((b.echo as Record<string, unknown>).op, "two");
  assert.equal((d.echo as Record<string, unknown>).op, "three");
  c.close();
  s.close();
});

test("未连接时 send 拒绝", async () => {
  const c = new TcpClient("127.0.0.1", 1);
  await assert.rejects(() => c.send({ op: "state" }), /not connected/);
});
