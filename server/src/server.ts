import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';

/** 构建 Fastify 应用（HTTP + WebSocket）。P4 会接入编排与世界状态路由。 */
export async function buildServer(): Promise<FastifyInstance> {
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });
  await app.register(websocket);

  app.get('/health', async () => ({ ok: true, service: 'maliang-server' }));

  // 占位 WS：P4 替换为意图/进度协议
  app.get('/ws', { websocket: true }, (socket) => {
    socket.on('message', (raw: Buffer) => socket.send(raw));
  });

  return app;
}
