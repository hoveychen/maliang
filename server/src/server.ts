import { randomUUID } from 'node:crypto';
import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';
import type { ServiceAdapters } from './adapters/types.ts';
import { createAdapters } from './adapters/factory.ts';
import { loadConfig } from './config.ts';
import { WorldStore } from './persistence.ts';
import { createCharacter, ModerationError } from './orchestrator.ts';
import { handleVoice } from './voice.ts';
import type { Character } from './types.ts';

export interface ServerDeps {
  adapters?: ServiceAdapters;
  store?: WorldStore;
}

/** 在世界中央种一个小神仙（默认能造角色）。 */
function seedFairy(worldId: string): Character {
  return {
    id: randomUUID(),
    worldId,
    isFairy: true,
    name: '小神仙',
    personality: '温柔的小神仙，能按小朋友的想法创造新伙伴。',
    voiceId: 'mock-voice-cn-fairy',
    appearance: { visualDescription: '发光的可爱小神仙', spriteAsset: '', scale: 1.2 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [{ type: 'wait', params: { duration: 1 } }], loop: true },
    position: { tileX: 500, tileY: 500 },
    abilities: ['move_to', 'deliver_message', 'create_character'],
    relationships: {},
  };
}

function characterListView(store: WorldStore, worldId: string) {
  return store.listCharacters(worldId);
}

export async function buildServer(deps: ServerDeps = {}): Promise<FastifyInstance> {
  const adapters = deps.adapters ?? createAdapters(loadConfig());
  const store = deps.store ?? new WorldStore();
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });
  await app.register(websocket);

  app.get('/health', async () => ({ ok: true, service: 'maliang-server' }));

  // 新建世界（种入小神仙）
  app.post('/worlds', async () => {
    const world = store.createWorld();
    store.addCharacter(seedFairy(world.id));
    return { id: world.id, characters: characterListView(store, world.id) };
  });

  // 拉世界状态
  app.get<{ Params: { id: string } }>('/worlds/:id', async (req, reply) => {
    const world = store.getWorld(req.params.id);
    if (!world) return reply.code(404).send({ error: 'world not found' });
    return { id: world.id, characters: characterListView(store, world.id) };
  });

  // 取生成的 sprite 资源
  app.get<{ Params: { hash: string } }>('/assets/:hash', async (req, reply) => {
    const asset = store.getAsset(req.params.hash);
    if (!asset) return reply.code(404).send({ error: 'asset not found' });
    return reply.header('content-type', asset.mime).send(Buffer.from(asset.bytes));
  });

  // WebSocket：造角色请求 → 进度推送 → 完成/失败
  app.get('/ws', { websocket: true }, (socket) => {
    socket.on('message', (raw: Buffer) => {
      void handleWsMessage(socket, raw.toString(), adapters, store);
    });
  });

  return app;
}

async function handleWsMessage(
  socket: { send: (data: string) => void },
  raw: string,
  adapters: ServiceAdapters,
  store: WorldStore,
): Promise<void> {
  let msg: {
    type?: string;
    worldId?: string;
    intentText?: string;
    byFairy?: boolean;
    characterId?: string;
    audio?: string; // base64
    format?: string;
  };
  try {
    msg = JSON.parse(raw);
  } catch {
    socket.send(JSON.stringify({ type: 'error', error: 'invalid json' }));
    return;
  }

  if (msg.type === 'create_character_request') {
    const requestId = randomUUID();
    const input = {
      worldId: msg.worldId ?? '',
      intentText: msg.intentText ?? '',
      byFairy: msg.byFairy ?? true,
    };
    try {
      const character = await createCharacter(input, adapters, store, (stage) => {
        socket.send(JSON.stringify({ type: 'gen_progress', requestId, stage }));
      });
      socket.send(JSON.stringify({ type: 'gen_complete', requestId, character }));
    } catch (err) {
      const reason = err instanceof ModerationError ? err.message : String(err);
      socket.send(JSON.stringify({ type: 'gen_failed', requestId, reason }));
    }
    return;
  }

  if (msg.type === 'voice_input') {
    try {
      const audioBytes = Uint8Array.from(Buffer.from(msg.audio ?? '', 'base64'));
      const response = await handleVoice(
        {
          worldId: msg.worldId ?? '',
          characterId: msg.characterId ?? '',
          audio: { bytes: audioBytes, mime: msg.format ?? 'audio/wav' },
        },
        adapters,
        store,
      );
      socket.send(JSON.stringify({ type: 'character_response', ...response }));
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    }
    return;
  }

  socket.send(JSON.stringify({ type: 'error', error: `unknown type: ${msg.type}` }));
}
