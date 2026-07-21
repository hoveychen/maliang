// 游戏客户端 debug TCP 命令口的 Node 客户端（game-pilot 重写 P4）。
// 对端 = scripts/debug_cmd_server.gd（仅 debug 构建）：一行一条 JSON 命令、回一行 JSON 应答。
// 移植自 test/e2e/harness.py 的行分帧 + 单持久连接。MCP 工具调用天然串行，故一发一收 FIFO 足矣。
// 类型剥离安全：无 enum/namespace/decorator/参数属性，仅用 node:net stdlib。
import net from "node:net";

export type Reply = Record<string, unknown>;

type Waiter = { resolve: (r: Reply) => void; reject: (e: Error) => void; timer: ReturnType<typeof setTimeout> };

export class TcpClient {
  host: string;
  port: number;
  private sock: net.Socket | null = null;
  private buf = "";
  private queue: Waiter[] = [];

  constructor(host = "127.0.0.1", port = 8578) {
    this.host = host;
    this.port = port;
  }

  connected(): boolean {
    return this.sock !== null;
  }

  connect(timeoutMs = 8000): Promise<void> {
    return new Promise((resolve, reject) => {
      const s = net.createConnection({ host: this.host, port: this.port });
      const to = setTimeout(() => {
        s.destroy();
        reject(new Error(`connect timeout ${this.host}:${this.port}`));
      }, timeoutMs);
      const onErr = (e: Error) => {
        clearTimeout(to);
        reject(e);
      };
      s.once("error", onErr);
      s.once("connect", () => {
        clearTimeout(to);
        s.removeListener("error", onErr);
        s.setEncoding("utf8");
        s.on("data", (d: string) => this.onData(d));
        s.on("error", (e: Error) => this.failAll(e));
        s.on("close", () => this.failAll(new Error("connection closed")));
        this.sock = s;
        resolve();
      });
    });
  }

  private onData(chunk: string): void {
    this.buf += chunk;
    let nl = this.buf.indexOf("\n");
    while (nl >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      nl = this.buf.indexOf("\n");
      if (!line.trim()) continue;
      const w = this.queue.shift();
      if (!w) continue;
      clearTimeout(w.timer);
      try {
        w.resolve(JSON.parse(line) as Reply);
      } catch (e) {
        w.reject(e as Error);
      }
    }
  }

  private failAll(e: Error): void {
    const q = this.queue;
    this.queue = [];
    for (const w of q) {
      clearTimeout(w.timer);
      w.reject(e);
    }
    this.sock = null;
  }

  // 发一条命令，等回一行应答。异步动作（do 走路/进场）对端落定才回 → 超时放宽。
  send(obj: Record<string, unknown>, timeoutMs = 30000): Promise<Reply> {
    const sock = this.sock;
    if (!sock) return Promise.reject(new Error("not connected"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        // 超时：移除该 waiter，避免后续应答错位
        const i = this.queue.findIndex((x) => x.timer === timer);
        if (i >= 0) this.queue.splice(i, 1);
        reject(new Error("reply timeout"));
      }, timeoutMs);
      this.queue.push({ resolve, reject, timer });
      sock.write(JSON.stringify(obj) + "\n");
    });
  }

  close(): void {
    if (this.sock) {
      this.sock.end();
      this.sock = null;
    }
  }
}
