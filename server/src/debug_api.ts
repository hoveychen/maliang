// 管理后台资源化只读 API（/debug/api/*）：React 多页面后台按资源单独拉取，
// 取代一次性全量 /debug/state（保留兼容）。只读直连 WorldStore，不改任何状态。
// 门禁与 /debug 同一套 admin token（authed 由 server.ts 注入）。
import type { FastifyInstance } from 'fastify';
import type { WorldStore } from './persistence.ts';
import type { Character } from './types.ts';
import { DEFAULT_SCENE } from './types.ts';

type AuthedFn = (req: { headers: Record<string, unknown>; query: unknown }) => boolean;

/** 角色列表页摘要（详情另拉，避免世界页背全部记忆/对话）。 */
function characterSummary(store: WorldStore, c: Character) {
  return {
    id: c.id,
    name: c.name,
    isFairy: c.isFairy,
    state: c.state,
    position: c.position,
    // 角色所在场景（存量缺省归 village）：后台地图按场景把角色画到对应场景上
    sceneId: c.sceneId ?? DEFAULT_SCENE,
    personality: c.personality,
    spriteAsset: c.appearance.spriteAsset,
    scale: c.appearance.scale,
    voiceId: c.voiceId,
    greetingStyle: c.greetingStyle ?? '',
    abilities: c.abilities,
    memoryCount: store.listMemories(c.id).length,
    chatTurnCount: store.listChatTurns(c.id).length,
    // 世界角色表一眼看出谁还没动画（详情页有完整 spriteAnim 记录）
    spriteAnimStatus: c.appearance.spriteAsset
      ? (store.getSpriteAnim(c.appearance.spriteAsset)?.status ?? 'none')
      : 'none',
  };
}

/** 世界列表页摘要。 */
function worldSummary(store: WorldStore, w: { id: string }) {
  const visits = store.listVisits(w.id);
  const characters = store.listCharacters(w.id);
  return {
    id: w.id,
    // 钱包与委托按玩家分：每个玩家各一条（匿名连接落在 playerId='' 上）
    wallets: store.listWallets(w.id),
    activeTasks: store.listActiveTasks(w.id),
    locations: store.getLocations(w.id),
    sceneCount: store.listScenes(w.id).length,
    characterCount: characters.length,
    fairyCount: characters.filter((c) => c.isFairy).length,
    propCount: store.listProps(w.id).length,
    visitCount: visits.length,
    activeVisitCount: visits.filter((v) => v.endedAt === null).length,
  };
}

export function registerDebugApi(app: FastifyInstance, store: WorldStore, authed: AuthedFn): void {
  const guard = (req: { headers: Record<string, unknown>; query: unknown }, reply: { code: (n: number) => { send: (b: unknown) => unknown } }): boolean => {
    if (authed(req)) return true;
    reply.code(403).send({ error: 'admin token required' });
    return false;
  };

  // 总览：各资源计数 + 最近会话动态（Dashboard 首屏）
  app.get('/debug/api/overview', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const worlds = store.listWorlds();
    let characters = 0;
    let props = 0;
    for (const w of worlds) {
      characters += store.listCharacters(w.id).length;
      props += store.listProps(w.id).length;
    }
    const visits = store.listVisits();
    return {
      players: store.listPlayers().length,
      worlds: worlds.length,
      characters,
      props,
      visits: { total: visits.length, active: visits.filter((v) => v.endedAt === null).length },
      creationIcons: Object.keys(store.listCreationIcons()).length,
      recentVisits: [...visits].sort((a, b) => b.startedAt - a.startedAt).slice(0, 20),
    };
  });

  // 玩家列表（带派生的会话统计，列表页直接可用）
  app.get('/debug/api/players', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const visits = store.listVisits();
    const byPlayer = new Map<string, { count: number; last: number }>();
    for (const v of visits) {
      const cur = byPlayer.get(v.playerId) ?? { count: 0, last: 0 };
      cur.count += 1;
      cur.last = Math.max(cur.last, v.startedAt);
      byPlayer.set(v.playerId, cur);
    }
    return {
      players: store.listPlayers().map((p) => ({
        ...p,
        visitCount: byPlayer.get(p.id)?.count ?? 0,
        lastVisitAt: byPlayer.get(p.id)?.last ?? null,
      })),
    };
  });

  // 玩家详情：档案 + 会话史 + 各角色对 TA 的记忆 + 与各角色的对话
  app.get<{ Params: { id: string } }>('/debug/api/players/:id', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const player = store.getPlayer(req.params.id);
    if (!player) return reply.code(404).send({ error: 'player not found' });
    const visits = store.listVisits().filter((v) => v.playerId === player.id);
    const memories: { worldId: string; characterId: string; characterName: string; items: unknown[] }[] = [];
    const chats: { worldId: string; characterId: string; characterName: string; turns: unknown[] }[] = [];
    for (const w of store.listWorlds()) {
      for (const c of store.listCharacters(w.id)) {
        const items = store.listMemories(c.id).filter((m) => m.aboutPlayer === player.id);
        if (items.length > 0) memories.push({ worldId: w.id, characterId: c.id, characterName: c.name, items });
        const turns = store.listChatTurns(c.id).filter((t) => t.playerId === player.id);
        if (turns.length > 0) chats.push({ worldId: w.id, characterId: c.id, characterName: c.name, turns });
      }
    }
    return {
      player,
      visits,
      memories,
      chats,
      // 玩家形象的 idle 动画状态（形象在设备档案，动画按 spriteAsset hash 绑定）
      spriteAnim: player.spriteAsset ? (store.getSpriteAnim(player.spriteAsset) ?? { status: 'none' }) : { status: 'none' },
    };
  });

  // 世界列表（计数摘要）
  app.get('/debug/api/worlds', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    return { worlds: store.listWorlds().map((w) => worldSummary(store, w)) };
  });

  // 世界详情：钱包/委托/地点 + 角色摘要 + 物品 + 会话（事件页 = 会话 + 委托）
  app.get<{ Params: { id: string } }>('/debug/api/worlds/:id', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const world = store.getWorld(req.params.id);
    if (!world) return reply.code(404).send({ error: 'world not found' });
    return {
      ...worldSummary(store, { id: world.id }),
      // 场景 = 世界里的每片区域（模型 B）：地形 hash/网格 + POI + 传送门，全结构透出给后台
      scenes: store.listScenes(world.id),
      characters: store.listCharacters(world.id).map((c) => characterSummary(store, c)),
      props: store.listProps(world.id),
      visits: store.listVisits(world.id),
    };
  });

  // 角色详情：完整角色（含行为脚本/关系/外观）+ 记忆 + 对话 + 立绘动画状态
  app.get<{ Params: { id: string; cid: string } }>('/debug/api/worlds/:id/characters/:cid', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const c = store.getCharacter(req.params.id, req.params.cid);
    if (!c) return reply.code(404).send({ error: 'character not found' });
    return {
      character: c,
      memories: store.listMemories(c.id),
      chatTurns: store.listChatTurns(c.id),
      spriteAnim: c.appearance.spriteAsset ? (store.getSpriteAnim(c.appearance.spriteAsset) ?? { status: 'none' }) : { status: 'none' },
    };
  });
}
