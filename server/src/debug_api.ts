// 管理后台资源化只读 API（/debug/api/*）：React 多页面后台按资源单独拉取，
// 取代一次性全量 /debug/state（保留兼容）。只读直连 WorldStore，不改任何状态。
// 门禁与 /debug 同一套 admin token（authed 由 server.ts 注入）。
import type { FastifyInstance } from 'fastify';
import type { WorldStore } from './persistence.ts';
import type { Character, ItemDef } from './types.ts';
import { DEFAULT_SCENE } from './types.ts';
import { decodeTerrain } from './terrain.ts';
import { BUILTIN_ITEMS } from './items.ts';

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
    itemCount: store.listWorldItems(w.id).length,
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
    let items = 0;
    for (const w of worlds) {
      characters += store.listCharacters(w.id).length;
      items += store.listWorldItems(w.id).length;
    }
    const visits = store.listVisits();
    return {
      players: store.listPlayers().length,
      worlds: worlds.length,
      characters,
      items,
      visits: { total: visits.length, active: visits.filter((v) => v.endedAt === null).length },
      creationIcons: Object.keys(store.listCreationIcons()).length,
      itemIcons: Object.keys(store.listItemIcons()).length,
      recentVisits: [...visits].sort((a, b) => b.startedAt - a.startedAt).slice(0, 20),
    };
  });

  // activity 记录：会话 + 设备快照，倒序分页。回答"谁、用什么设备、何时来、玩多久"。
  app.get<{ Querystring: { limit?: string; offset?: string } }>('/debug/api/activity', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const limit = Math.max(1, Math.min(500, Number(req.query.limit) || 100));
    const offset = Math.max(0, Number(req.query.offset) || 0);
    const rows = store.listActivity(limit, offset);
    // 派生玩家昵称（活动行只存 playerId，列表直接可读省一次前端 join）
    const players = new Map(store.listPlayers().map((p) => [p.id, p.nickname || p.name || '']));
    return {
      total: store.countVisits(),
      limit,
      offset,
      activity: rows.map((v) => ({
        id: v.id,
        worldId: v.worldId,
        playerId: v.playerId,
        playerName: players.get(v.playerId) ?? '',
        startedAt: v.startedAt,
        endedAt: v.endedAt,
        durationMs: v.endedAt !== null ? v.endedAt - v.startedAt : null,
        device: v.device ?? null,
      })),
    };
  });

  // 物品实体全景（顶层「物品」页）：内置定义（items.ts 代码常量，worldId=null）+ 所有世界的
  // 语音造物，各带客户端上传的外观缩略图 hash 与「被多少场景引用」的粗略用量。内置 def 在别处
  // 都看不到，这页是唯一入口。用量 = palette 里出现过该 id 的场景数（矩阵 v2 palette 只收被引用
  // 的实体，够用作 debug 指标；精确到 tile 数不值这个解码成本）。
  app.get('/debug/api/items', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const icons = store.listItemIcons();
    // 用量：扫所有世界所有场景的 palette，统计每个 item id 出现的场景数
    const sceneRefs = new Map<string, number>();
    for (const w of store.listWorlds()) {
      for (const sc of store.listScenes(w.id)) {
        const rec = store.getSceneTerrain(w.id, sc.sceneId);
        if (!rec) continue;
        let palette: string[];
        try {
          palette = decodeTerrain(rec.bytes).palette;
        } catch {
          continue; // 坏矩阵不该拖垮整页
        }
        for (const id of new Set(palette)) sceneRefs.set(id, (sceneRefs.get(id) ?? 0) + 1);
      }
    }
    const decorate = (def: ItemDef) => ({
      ...def,
      iconHash: icons[def.id] ?? '',
      sceneRefs: sceneRefs.get(def.id) ?? 0,
    });
    const builtin = BUILTIN_ITEMS.map(decorate);
    const creations: ReturnType<typeof decorate>[] = [];
    for (const w of store.listWorlds()) {
      for (const def of store.listWorldItems(w.id)) creations.push(decorate(def));
    }
    return {
      builtin,
      creations,
      counts: {
        builtin: builtin.length,
        creations: creations.length,
        withIcon: [...builtin, ...creations].filter((i) => i.iconHash).length,
      },
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
    const stored = store.getPlayer(req.params.id);
    const onboardingProfile = store.getOnboardingProfile(req.params.id);
    // 刚建完形象还没进过世界的孩子只在 player_onboarding（players 表要 world_info 才 upsert）：
    // 用 onboarding 档案合成最小 Player，详情页不 404、能看到 TA 的创建档案。
    if (!stored && !onboardingProfile) return reply.code(404).send({ error: 'player not found' });
    const player = stored ?? {
      id: req.params.id,
      name: onboardingProfile!.name,
      nickname: onboardingProfile!.nickname,
      gender: '',
      color: onboardingProfile!.attrs.color ?? '',
      spriteAsset: onboardingProfile!.spriteAsset,
      createdAt: onboardingProfile!.createdAt,
    };
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
      // onboarding 档案（结构化属性+最终描述+refine 原话；无档案为 null——additive 字段，管理台旧页面不受影响）
      onboarding: onboardingProfile ?? null,
    };
  });

  // onboarding 档案总表（docs/onboarding-avatar-redesign-design.md §2.5：管理台可见每个孩子的档案）
  app.get('/debug/api/onboarding-profiles', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    return { profiles: store.listOnboardingProfiles() };
  });

  // 世界列表（计数摘要）
  app.get('/debug/api/worlds', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    return { worlds: store.listWorlds().map((w) => worldSummary(store, w)) };
  });

  // 世界详情：钱包/委托/地点 + 角色摘要 + 造物实体/背包 + 会话（事件页 = 会话 + 委托）
  app.get<{ Params: { id: string } }>('/debug/api/worlds/:id', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const world = store.getWorld(req.params.id);
    if (!world) return reply.code(404).send({ error: 'world not found' });
    return {
      ...worldSummary(store, { id: world.id }),
      // 场景 = 世界里的每片区域（模型 B）：地形 hash/网格 + POI + 传送门，全结构透出给后台
      scenes: store.listScenes(world.id),
      characters: store.listCharacters(world.id).map((c) => characterSummary(store, c)),
      // 造物实体行（摆着的引用在场景矩阵里，见 terrain-grid 端点）+ 各玩家背包计数
      items: store.listWorldItems(world.id),
      bags: store.listBags(world.id),
      visits: store.listVisits(world.id),
    };
  });

  // 场景地形矩阵（解码成 JSON 供后台矩阵图渲染：地貌三平面 + 物品层 + palette 实体定义）。
  // 服务端解码复用唯一编解码器（terrain.ts），后台不抄第二份格式实现。
  app.get<{ Params: { id: string; sid: string } }>('/debug/api/worlds/:id/scenes/:sid/terrain-grid', async (req, reply) => {
    if (!guard(req, reply)) return reply;
    const rec = store.getSceneTerrain(req.params.id, req.params.sid);
    if (!rec) return reply.code(404).send({ error: 'scene terrain not found' });
    const t = decodeTerrain(rec.bytes);
    const resolve = store.itemResolver(req.params.id);
    return {
      version: rec.version,
      gridW: t.gridW,
      gridH: t.gridH,
      types: Array.from(t.types),
      heights: Array.from(t.heights),
      depths: Array.from(t.depths),
      itemRef: Array.from(t.itemRef),
      itemArg: Array.from(t.itemArg),
      palette: t.palette,
      items: t.palette.map((id) => resolve(id) ?? null),
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
