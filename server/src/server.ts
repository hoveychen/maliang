import { randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pipeline } from 'node:stream';
import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';
import fastifyStatic from '@fastify/static';
import type { ServiceAdapters } from './adapters/types.ts';
import { createAdapters } from './adapters/factory.ts';
import { loadConfig } from './config.ts';
import { WorldStore } from './persistence.ts';
import { startBackup, restoreBackup, type BackupExport } from './backup.ts';

/** 上传备份包的体量兜底。正常包只有几十 MB，这个数只是防止有人拿它当上传洞。 */
const MAX_RESTORE_UPLOAD = 2 * 1024 * 1024 * 1024;

/**
 * If-None-Match 是否命中某个 ETag。按 RFC 9110：可以是逗号分隔的多个 tag，
 * 也可能带弱校验前缀 W/（代理/浏览器都会这么发），逐个剥掉再比。
 */
function etagMatches(header: string | string[] | undefined, etag: string): boolean {
  if (typeof header !== 'string') return false;
  return header.split(',').some((t) => t.trim().replace(/^W\//, '') === etag);
}

/**
 * 取客户端真实 IP。muvee 是反代，socket 远端地址是反代自己的 IP，真实客户端 IP 在
 * x-forwarded-for（可能是 "client, proxy1, proxy2" 链，取最左即最初的客户端）。
 * 没有该头（本地直连/测试）就退回 fastify 的 req.ip。
 */
export function clientIp(req: { headers: Record<string, unknown>; ip?: string }): string | undefined {
  const xff = req.headers['x-forwarded-for'];
  const raw = Array.isArray(xff) ? xff[0] : xff;
  if (typeof raw === 'string' && raw.trim()) return raw.split(',')[0]!.trim().slice(0, 64);
  return req.ip && req.ip.length ? req.ip.slice(0, 64) : undefined;
}

/** 合成设备快照：连接层（IP/UA）+ 客户端上报（机型/系统等）。全空则返回 null（旧客户端不带）。 */
export function buildDeviceSnapshot(
  session: { connIp?: string; connUa?: string },
  reported: DeviceReport | undefined,
): DeviceSnapshot | null {
  const s = (v: unknown, n: number): string | undefined => {
    if (typeof v !== 'string') return undefined;
    const t = v.trim();
    return t ? t.slice(0, n) : undefined;
  };
  const snap: DeviceSnapshot = {
    ip: s(session.connIp, 64),
    ua: s(session.connUa, 512),
    model: s(reported?.model, 128),
    os: s(reported?.os, 64),
    osVersion: s(reported?.osVersion, 64),
    screen: s(reported?.screen, 32),
    godot: s(reported?.godot, 64),
    app: s(reported?.app, 64),
  };
  return Object.values(snap).some((v) => v !== undefined) ? snap : null;
}

/** 客户端在 world_info.profile.device 里上报的设备块（都可选、都当不可信输入夹紧）。 */
interface DeviceReport {
  model?: string;
  os?: string;
  osVersion?: string;
  screen?: string;
  godot?: string;
  app?: string;
}
import { createCharacter, generateSprite, generateIconAsset, ModerationError } from './orchestrator.ts';
import { detectCharacterAnchors } from './anchors.ts';
import { trimToContent } from './adapters/chroma_cutout.ts';
import { generateCharacterAnimation, triggerCharacterAnimation, backfillCharacterAnimations, repackFromStoredClips, type ToSpriteSheet } from './idle_animation.ts';
import type { SpriteSheetMeta } from './sprite_sheet.ts';
import { FAIRY_VISUAL_DESC } from './adapters/sprite_style.ts';
import { respondToTranscript, greetCharacter, flushMemory } from './voice.ts';
import { validateSdfPropSpec } from './sdf_prop.ts';
import { decodeTerrain, encodeTerrain } from './terrain.ts';
import { BUILTIN_ITEMS, creationItemDef, creationStickerDef, creationBuildDef, getBuiltinItem, validateTerrainItems } from './items.ts';
import { matchBlueprint, findBlueprint, type ComposedPart, type ComposedSpec } from './build_blueprints.ts';
import { findPart, partsForSlot } from './part_library.ts';
import { editSceneTerrain, TerrainEditError, type TileEditInput } from './terrain_edit.ts';
import { BENCH_VERSION, aggregateLevels, normalizeGpu, sanitizeSample } from './device_profile.ts';
import { RateLimiter } from './ratelimit.ts';
import { registerDebugApi } from './debug_api.ts';
import { newCreationState, isValidTile, ANON_PLAYER, DEFAULT_SCENE, FAIRY_NAME, FAIRY_PERSONALITY, INITIAL_FLOWERS, WORLD_CENTER_TILE, type ActiveTask, type AnchorPoint, type Character, type CharacterAnchors, type ChatTurn, type CreationGoal, type CreationState, type DeviceSnapshot, type Player, type Scene, type ScenePoi, type ScenePortal, type TilePos, type VoiceResponse, type Wallet } from './types.ts';
import { CREATION_OPTIONS, findOption, iconPrompt, sizeToScale, scaleToSize, type CreatureSize } from './creation_options.ts';
import { findPropOption, composePropDesc, PROP_CREATION_OPTIONS, propIconPrompt } from './prop_creation_options.ts';
import { findStickerOption, composeStickerDesc, STICKER_CREATION_OPTIONS, stickerIconPrompt } from './sticker_creation_options.ts';
import { seedForestCharacters } from './forest_characters.ts';
import { completeTaskOnEvent, completeWishOnAbility, beginWishTrial, completeWishRefine, flowerDeniedLine, praiseLine } from './tasks.ts';
import { pickComplaint, REFINE_HINT, REFINE_HINT_2 } from './refinements.ts';
import { wishFor, IDLE_DOING } from './wishes.ts';
import { backfillVoices, FAIRY_VOICE, voiceForPlayer } from './voice_catalog.ts';
import { WorldHub } from './world_hub.ts';
import { StageDirector, DEFAULT_MAX_CONCURRENT_STAGES, type StageStartOpts } from './stage_session.ts';
import { buildDebut, DebutError } from './stage_debut.ts';
import { buildStageOptsFromDraft } from './screenplay_gen.ts';
import { SCREENPLAYS, type ScreenplayName } from './screenplays.ts';
import type { StagePropMaker } from './stage_types.ts';
import { POS_TAG_REPORT, decodeReport, encodeRelay } from './pos_codec.ts';

export interface ServerDeps {
  adapters?: ServiceAdapters;
  store?: WorldStore;
  /** 视频→图集转换缝（缺省真实 ffmpeg；测试注入假实现以免依赖网络/ffmpeg）。 */
  toSpriteSheet?: ToSpriteSheet;
  /** 启动时回填存量角色的 idle 动画（只在真实进程入口 index.ts 开；测试建 server 不触发生成）。 */
  backfillOnBoot?: boolean;
}

/** 按 magic bytes 识别图片 mime（上传的图集可能是 PNG 或 WebP）。 */
function sniffImageMime(b: Uint8Array): string {
  if (b[0] === 0x89 && b[1] === 0x50) return 'image/png';
  if (
    b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
    b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50
  ) return 'image/webp';
  if (b[0] === 0xff && b[1] === 0xd8) return 'image/jpeg';
  return 'image/png';
}

/** 在世界中央种一个点点（默认能造角色）。 */
export function seedFairy(worldId: string): Character {
  return {
    id: randomUUID(),
    worldId,
    isFairy: true,
    name: FAIRY_NAME,
    personality: FAIRY_PERSONALITY,
    voiceId: FAIRY_VOICE,
    appearance: { visualDescription: FAIRY_VISUAL_DESC, spriteAsset: '', scale: 1.2 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [{ type: 'wait', params: { duration: 1 } }], loop: true },
    position: WORLD_CENTER_TILE,
    sceneId: DEFAULT_SCENE,
    // 不含 move_to / deliver_message：effectiveAbilities 对 isFairy 恒剔除 LOCOMOTION_ABILITIES，
    // 留在数组里只是历史残留（她拿到也兑现不了——笔没有腿）。
    abilities: ['create_character', 'create_prop', 'create_sticker', 'play_game', 'guide_to', 'guide_stop'],
    relationships: {},
  };
}

function characterListView(store: WorldStore, worldId: string) {
  return store.listCharacters(worldId);
}

/** 只读后台快照（P6）：玩家 + 每个世界的角色（含记忆/对话）+ 造物实体/背包 + Visit。直连 WorldStore，不改状态。 */
export function buildDebugState(store: WorldStore) {
  return {
    players: store.listPlayers(),
    worlds: store.listWorlds().map((w) => ({
      id: w.id,
      wallets: w.wallets,
      activeTasks: w.activeTasks,
      characters: store.listCharacters(w.id).map((c) => ({
        id: c.id,
        name: c.name,
        isFairy: c.isFairy,
        personality: c.personality,
        state: c.state,
        position: c.position,
        memories: store.listMemories(c.id),
        chatTurns: store.listChatTurns(c.id),
      })),
      items: store.listWorldItems(w.id),
      bags: store.listBags(w.id),
      visits: store.listVisits(w.id),
    })),
  };
}

/** 单页只读 dashboard：拉 /debug/state 渲染。纯静态 HTML+JS，token 从本页 URL 透传给 state 接口。 */
const DEBUG_DASHBOARD_HTML = `<!doctype html>
<html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>maliang 状态后台</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.5 -apple-system,system-ui,"PingFang SC",sans-serif; margin: 0; background:#f5f3ee; color:#222; }
  header { padding: 14px 20px; background:#2b2b2b; color:#f5f3ee; display:flex; align-items:baseline; gap:12px; }
  header h1 { font-size: 16px; margin:0; font-weight:600; }
  header .meta { font-size:12px; opacity:.7; }
  header button { margin-left:auto; font-size:12px; padding:4px 12px; border-radius:6px; border:1px solid #666; background:#3a3a3a; color:#eee; cursor:pointer; }
  main { padding: 16px 20px 60px; max-width: 1100px; }
  h2 { font-size:14px; margin: 22px 0 8px; border-bottom:2px solid #d9d3c7; padding-bottom:4px; }
  table { border-collapse: collapse; width:100%; margin:6px 0 14px; background:#fffdf8; }
  th,td { text-align:left; padding:5px 9px; border:1px solid #e4ddcf; vertical-align:top; }
  th { background:#efe9dd; font-weight:600; }
  .world { border:1px solid #d9d3c7; border-radius:8px; padding:12px 14px; margin:14px 0; background:#fbf9f3; }
  .world > .wid { font-weight:600; font-size:13px; }
  .kind { display:inline-block; font-size:11px; padding:1px 6px; border-radius:4px; background:#e7e0d0; margin-right:4px; }
  .mono { font-family:"SF Mono",ui-monospace,Menlo,monospace; font-size:12px; color:#555; }
  .empty { color:#999; font-style:italic; }
  .err { color:#b00; padding:20px; }
  details { margin:4px 0; } summary { cursor:pointer; font-size:13px; }
</style></head>
<body>
<header><h1>🧚 maliang 状态后台</h1><span class="meta" id="meta">加载中…</span><button onclick="load()">刷新</button></header>
<main id="app"></main>
<script>
const token = new URLSearchParams(location.search).get('token');
const esc = (s) => String(s ?? '').replace(/[&<>]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
function kindsOf(mems){ const by={}; for(const m of mems){ (by[m.kind]=by[m.kind]||[]).push(m.text); } return by; }
function charBlock(c){
  const byKind = kindsOf(c.memories);
  const memHtml = c.memories.length ? Object.entries(byKind).map(([k,ts]) =>
    '<div><span class="kind">'+esc(k)+'</span>'+ts.map(esc).join('；')+'</div>').join('') : '<span class="empty">（无记忆）</span>';
  const turns = c.chatTurns.slice(-12);
  const turnHtml = turns.length ? turns.map(t =>
    '<div class="mono">['+esc(t.playerId||'∅')+'] '+(t.role==='child'?'👦':'🧸')+' '+esc(t.text)+'</div>').join('') : '<span class="empty">（无对话）</span>';
  return '<details'+(c.isFairy?'':' open')+'><summary><b>'+esc(c.name)+'</b> '+(c.isFairy?'🧚':'')+
    ' <span class="mono">'+esc(c.id.slice(0,8))+' · '+esc(c.state)+' · ('+c.position.tileX+','+c.position.tileY+')</span>'+
    ' <span class="mono">记忆'+c.memories.length+' 对话'+c.chatTurns.length+'</span></summary>'+
    '<div style="padding:6px 0 6px 14px">'+esc(c.personality)+'<h4 style="margin:8px 0 2px;font-size:12px">记忆</h4>'+memHtml+
    '<h4 style="margin:8px 0 2px;font-size:12px">近期对话（末12条）</h4>'+turnHtml+'</div></details>';
}
function render(s){
  document.getElementById('meta').textContent = s.players.length+' 玩家 · '+s.worlds.length+' 世界';
  let h = '<h2>玩家 Players ('+s.players.length+')</h2>';
  h += s.players.length ? '<table><tr><th>id</th><th>名字</th><th>昵称</th><th>性别</th><th>颜色</th><th>建档</th></tr>'+
    s.players.map(p => '<tr><td class="mono">'+esc(p.id.slice(0,12))+'</td><td>'+esc(p.name)+'</td><td>'+esc(p.nickname)+'</td><td>'+esc(p.gender)+'</td><td>'+esc(p.color)+'</td><td class="mono">'+esc(p.createdAt)+'</td></tr>').join('')+'</table>'
    : '<p class="empty">（无玩家）</p>';
  for(const w of s.worlds){
    h += '<div class="world"><div class="wid">世界 '+esc(w.id)+'</div>';
    const taskOf = pid => { const t = w.activeTasks.find(t => t.playerId === pid); return t ? t.task.type+'('+t.task.npcName+')' : '无'; };
    const pname = pid => pid ? pid.slice(0,8) : '(匿名)';
    h += w.wallets.length ? w.wallets.map(x => '<div class="mono">'+esc(pname(x.playerId))+' · 钱包 '+esc(JSON.stringify(x.wallet))+' · 委托 '+esc(taskOf(x.playerId))+'</div>').join('')
      : '<div class="mono empty">（无玩家钱包）</div>';
    h += '<h4 style="margin:10px 0 2px">角色 ('+w.characters.length+')</h4>'+ (w.characters.map(charBlock).join('')||'<span class="empty">（无角色）</span>');
    h += '<h4 style="margin:10px 0 2px">造物 ('+w.items.length+') · Visit ('+w.visits.length+')</h4>';
    h += '<div class="mono">'+w.visits.slice(0,10).map(v => v.playerId.slice(0,8)+' '+new Date(v.startedAt).toLocaleString()+(v.endedAt?' → 已结束':' · 进行中')).join('<br>')+'</div>';
    h += '</div>';
  }
  document.getElementById('app').innerHTML = h;
}
async function load(){
  try{
    const r = await fetch('/debug/state'+(token?('?token='+encodeURIComponent(token)):''), {headers: token?{'x-admin-token':token}:{}});
    if(!r.ok){ document.getElementById('app').innerHTML='<p class="err">加载失败 '+r.status+'（需要 ?token=）</p>'; return; }
    render(await r.json());
  }catch(e){ document.getElementById('app').innerHTML='<p class="err">'+esc(e)+'</p>'; }
}
load();
</script></body></html>`;

export async function buildServer(deps: ServerDeps = {}): Promise<FastifyInstance> {
  const adapters = deps.adapters ?? createAdapters(loadConfig());
  const store = deps.store ?? new WorldStore(process.env.MALIANG_DATA_DIR ?? './data');
  const toSpriteSheet = deps.toSpriteSheet;
  const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } });
  await app.register(websocket);

  app.get('/health', async () => ({ ok: true, service: 'maliang-server', version: process.env.GIT_SHA ?? 'dev' }));

  // —— 设备画质档众包（见 device_profile.ts）——
  // 启动时按 GPU 查：命中就直接用别人测过的档，这台机器不用当小白鼠跑 benchmark。
  app.get<{ Querystring: { gpu?: string; benchVersion?: string } }>('/device-profile', async (req, reply) => {
    const gpu = normalizeGpu(req.query.gpu);
    if (!gpu) return reply.code(400).send({ error: 'gpu required' });
    const version = Number(req.query.benchVersion ?? BENCH_VERSION);
    if (!Number.isInteger(version) || version < 1) return reply.code(400).send({ error: 'bad benchVersion' });
    const samples = store.listDeviceLevels(gpu, version);
    const levels = aggregateLevels(samples);
    return { found: levels !== null, levels: levels ?? undefined, samples: samples.length, gpu, benchVersion: version };
  });

  // benchmark 跑完上传本机结果，回传的是「算上你这票之后」的聚合档。
  app.post('/device-profile', async (req, reply) => {
    const sample = sanitizeSample(req.body);
    if (!sample) return reply.code(400).send({ error: 'bad sample' });
    store.putDeviceSample(sample);
    const levels = aggregateLevels(store.listDeviceLevels(sample.gpu, sample.benchVersion));
    return { ok: true, levels: levels ?? sample.levels, samples: store.listDeviceLevels(sample.gpu, sample.benchVersion).length };
  });

  // 新建世界（种入点点）
  app.post('/worlds', async () => {
    const world = store.createWorld();
    store.addCharacter(seedFairy(world.id));
    return { id: world.id, characters: characterListView(store, world.id) };
  });

  // 拉世界状态。固定的 "default" 世界不存在时自动创建并种入点点
  // （初始村民由 seed 脚本生成；客户端默认加载 default 世界）。
  app.get<{ Params: { id: string } }>('/worlds/:id', async (req, reply) => {
    let world = store.getWorld(req.params.id);
    if (!world && req.params.id === 'default') {
      world = store.createWorld('default');
      store.addCharacter(seedFairy('default'));
    }
    if (!world) return reply.code(404).send({ error: 'world not found' });
    // scenes 可能为空（地形还没入库）——客户端据此回退本地确定性生成，不影响老客户端。
    // items = 物品实体定义（内置 + 该世界造物）：矩阵 palette 引用的语义/渲染依据，
    // 客户端凭它渲染物品层与派生占用（万物皆物品，docs/scene-item-refactor-design.md）。
    return {
      id: world.id,
      characters: characterListView(store, world.id),
      scenes: store.listScenes(world.id),
      items: [...BUILTIN_ITEMS, ...store.listWorldItems(world.id)],
    };
  });

  // 为世界里的点点补一张真实 sprite。幂等：已有则跳过；?force=true 强制重生成；
  // body 带 pngBase64 时直接存该图（部署验收过的候选，确定性替换，隐含 force）。
  app.post<{
    Params: { id: string };
    Querystring: { force?: string };
    Body: { pngBase64?: string } | null;
  }>('/worlds/:id/fairy-sprite', { bodyLimit: 8 * 1024 * 1024 }, async (req, reply) => {
    const fairy = characterListView(store, req.params.id).find((c) => c.isFairy);
    if (!fairy) return reply.code(404).send({ error: 'no fairy in world' });
    const provided = req.body?.pngBase64;
    const force = req.query.force === 'true' || req.query.force === '1';
    if (fairy.appearance.spriteAsset && !force && !provided) {
      return { id: fairy.id, spriteAsset: fairy.appearance.spriteAsset, regenerated: false };
    }
    // 仙子走 NPC 同款 vision 锚点检测（每个仙子用自己立绘的真锚点，消除"锚点不落"例外，见设计 §5）。
    let hash: string;
    let anchors: CharacterAnchors | null;
    if (provided) {
      const blob = { bytes: Uint8Array.from(Buffer.from(provided, 'base64')), mime: 'image/png' };
      hash = store.putAsset(blob);
      anchors = await detectCharacterAnchors(adapters.anchors, blob);
    } else {
      const gen = await generateSprite(adapters, FAIRY_VISUAL_DESC, store);
      hash = gen.hash;
      anchors = gen.anchors;
    }
    fairy.appearance.spriteAsset = hash;
    fairy.appearance.visualDescription = FAIRY_VISUAL_DESC;
    if (anchors) fairy.appearance.anchors = anchors;
    store.saveCharacter(fairy);
    // 试点：静态立绘先返回，idle 动画后台异步补（客户端轮询 /sprite-anim/:hash）
    triggerCharacterAnimation(adapters, store, hash, toSpriteSheet);
    return { id: fairy.id, spriteAsset: hash, regenerated: true };
  });

  // 管理端点：按存量 visualDescription 重生成任意角色立绘（清理旧 prompt 时代
  // 朝向随机的存量素材用，见 tools/regen_old_sprites.mjs）。走完整管线（含朝向兜底）。
  // 生图烧钱且会改小朋友认得的角色形象，必须配 MALIANG_ADMIN_TOKEN 才开放。
  app.post<{ Params: { id: string; cid: string } }>(
    '/worlds/:id/characters/:cid/regen-sprite',
    async (req, reply) => {
      const token = process.env.MALIANG_ADMIN_TOKEN;
      if (!token || req.headers['x-admin-token'] !== token) {
        return reply.code(403).send({ error: 'admin token required' });
      }
      const char = store.getCharacter(req.params.id, req.params.cid);
      if (!char) return reply.code(404).send({ error: 'character not found' });
      const desc = char.appearance.visualDescription.trim();
      if (desc.length === 0) return reply.code(400).send({ error: 'character has no visualDescription' });
      const prev = char.appearance.spriteAsset;
      const gen = await generateSprite(adapters, desc, store);
      char.appearance.spriteAsset = gen.hash;
      if (gen.anchors) char.appearance.anchors = gen.anchors; // 新立绘=新坐标系，锚点必须一起换
      store.saveCharacter(char);
      return { id: char.id, name: char.name, prev, spriteAsset: gen.hash };
    },
  );

  // 管理端点：修数据用的角色 PATCH——sceneId / position / spriteAsset 按需改（scene-drag-guard P2）。
  // positions_report 已拒绝跨场景拖拽，角色换场景（如把被拖走的森林村民搬回去）走这里；
  // spriteAsset 用于把误 regen 的形象指回库里仍在的旧资产（regen-sprite 没有 undo）。
  // 全部字段可选、逐项校验：sceneId 必须已入库，position 必须界内，spriteAsset 必须在资产库。
  // 必须配 MALIANG_ADMIN_TOKEN。
  app.patch<{
    Params: { id: string; cid: string };
    Body: { sceneId?: string; position?: { tileX?: number; tileY?: number }; spriteAsset?: string } | null;
  }>('/admin/worlds/:id/characters/:cid', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const char = store.getCharacter(req.params.id, req.params.cid);
    if (!char) return reply.code(404).send({ error: 'character not found' });
    const b = req.body ?? {};
    if (b.sceneId !== undefined) {
      if (typeof b.sceneId !== 'string' || !store.getScene(req.params.id, b.sceneId)) {
        return reply.code(400).send({ error: `scene not registered: ${String(b.sceneId)}` });
      }
      char.sceneId = b.sceneId;
    }
    if (b.position !== undefined) {
      const tile: TilePos = { tileX: Number(b.position?.tileX), tileY: Number(b.position?.tileY) };
      if (!isValidTile(tile)) return reply.code(400).send({ error: 'position out of bounds' });
      char.position = tile;
    }
    if (b.spriteAsset !== undefined) {
      if (typeof b.spriteAsset !== 'string' || !store.getAsset(b.spriteAsset)) {
        return reply.code(400).send({ error: `asset not found: ${String(b.spriteAsset)}` });
      }
      char.appearance.spriteAsset = b.spriteAsset;
    }
    store.saveCharacter(char);
    return {
      id: char.id,
      name: char.name,
      sceneId: char.sceneId,
      position: char.position,
      spriteAsset: char.appearance.spriteAsset,
    };
  });

  // 管理端点：把小红花数直接设为指定值（缺省 INITIAL_FLOWERS）。补花用，不改经济规则。
  // 钱包按 (worldId, playerId) 分：
  //   body.playerId 给了 → 只补那个孩子（即便他还没建钱包，也会就地建出来）。
  //   没给           → 补该世界所有已有钱包的玩家（含匿名键）；一个都没有则补匿名键。
  // 只动 flowers，盖章进度保留。必须配 MALIANG_ADMIN_TOKEN。
  app.post<{ Params: { id: string }; Body: { flowers?: number; playerId?: string } | null }>(
    '/admin/worlds/:id/flowers',
    async (req, reply) => {
      const token = process.env.MALIANG_ADMIN_TOKEN;
      if (!token || req.headers['x-admin-token'] !== token) {
        return reply.code(403).send({ error: 'admin token required' });
      }
      const world = store.getWorld(req.params.id);
      if (!world) return reply.code(404).send({ error: 'world not found' });
      const n = req.body?.flowers ?? INITIAL_FLOWERS;
      if (typeof n !== 'number' || !Number.isFinite(n)) {
        return reply.code(400).send({ error: 'flowers must be a number' });
      }
      const target = req.body?.playerId;
      if (typeof target === 'string') {
        return { id: req.params.id, wallets: [{ playerId: target, wallet: store.setFlowers(req.params.id, target, n) }] };
      }
      const existing = store.listWallets(req.params.id).map((w) => w.playerId);
      const targets = existing.length > 0 ? existing : [ANON_PLAYER];
      return {
        id: req.params.id,
        wallets: targets.map((pid) => ({ playerId: pid, wallet: store.setFlowers(req.params.id, pid, n) })),
      };
    },
  );

  // 管理端点：清掉后台「无立绘」空玩家档（name 与 spriteAsset 均空）。这些是客户端在小朋友
  // 还没建角色时带全空 profile 上报 world_info 留下的脏数据（根因已在 world_info handler 堵死，
  // 此端点用来清历史）。必须配 MALIANG_ADMIN_TOKEN。返回被删的 playerId 列表与计数。
  app.post('/admin/players/prune-empty', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const removed = store.deleteEmptyPlayers();
    return { removed: removed.length, playerIds: removed };
  });

  // 管理端点：场景入库（地形 + POI + portal）。地形二进制经 base64 传入，解码校验后
  // 进内容寻址资产库；scenes 表只记 hash。同一份地形重复入库 → hash 相同 → 客户端不重下。
  // 见 docs/multi-scene-design.md 与 tools/export_terrain.gd。
  app.post<{
    Body: {
      worldId?: string;
      sceneId?: string;
      name?: string;
      terrainBase64?: string;
      pois?: ScenePoi[];
      portals?: ScenePortal[];
    } | null;
  }>('/admin/scenes', { bodyLimit: 4 * 1024 * 1024 }, async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const worldId = (req.body?.worldId ?? '').trim();
    const sceneId = (req.body?.sceneId ?? DEFAULT_SCENE).trim();
    const b64 = req.body?.terrainBase64 ?? '';
    if (!worldId) return reply.code(400).send({ error: 'worldId required' });
    if (!b64) return reply.code(400).send({ error: 'terrainBase64 required' });
    if (!store.getWorld(worldId)) return reply.code(404).send({ error: 'world not found' });

    let terrain;
    const bytes = new Uint8Array(Buffer.from(b64, 'base64'));
    try {
      terrain = decodeTerrain(bytes); // 坏地形在入库这一刻就拒收，别等渲染出问题才发现
    } catch (e) {
      return reply.code(400).send({ error: (e as Error).message });
    }

    // 物品语义校验（palette 可解析/占地冲突/压水压路）也在入库这一刻做——
    // 上传的可能是 v1（物品层全零，天然通过）或导出工具产的 v2
    try {
      validateTerrainItems(terrain, store.itemResolver(worldId));
    } catch (e) {
      return reply.code(400).send({ error: (e as Error).message });
    }

    const canonical = encodeTerrain(terrain); // 统一存 v2（v1 上传重编码，物品层补零）
    const terrainAsset = store.putAsset({ bytes: canonical, mime: 'application/octet-stream' });
    const prev = store.getScene(worldId, sceneId);
    const scene: Scene = {
      worldId,
      sceneId,
      name: (req.body?.name ?? sceneId).trim(),
      terrainAsset,
      gridTiles: terrain.gridW,
      pois: req.body?.pois ?? [],
      portals: req.body?.portals ?? [],
      terrainVersion: (prev?.terrainVersion ?? 0) + 1,
    };
    store.upsertScene(scene);
    store.setSceneTerrain(worldId, sceneId, canonical, scene.terrainVersion);
    return { scene, bytes: canonical.length };
  });

  // 场景地形矩阵全量下载（v2 blob）。响应头带版本，客户端按 (world, scene, version) 缓存；
  // terrain_patch 版本对不上时也从这里全量重拉。
  app.get<{ Params: { wid: string; sid: string } }>('/worlds/:wid/scenes/:sid/terrain', async (req, reply) => {
    const rec = store.getSceneTerrain(req.params.wid, req.params.sid);
    if (!rec) return reply.code(404).send({ error: 'scene terrain not found' });
    reply.header('x-terrain-version', String(rec.version));
    reply.type('application/octet-stream');
    return reply.send(Buffer.from(rec.bytes));
  });

  // 管理端点：存量角色锚点回填（docs/character-anchors-design.md §2.3，retrim 先例）。
  // 扫全库有 spriteAsset 的角色，缺 anchors（或 ?force=1 全量重算）的过一遍 vision 检测
  // （失败走像素兜底，见 anchors.ts）并原地写回。vision 走钱但每角色只一次 flash 调用。
  // ?world=<id> 限定单个世界。必须配 MALIANG_ADMIN_TOKEN。
  app.post<{ Querystring: { world?: string; force?: string } }>('/admin/detect-anchors', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const worldFilter = req.query.world;
    const force = req.query.force === '1';
    const results: { id: string; name: string; source?: string; skipped?: string }[] = [];
    for (const w of store.listWorlds().filter((x) => !worldFilter || x.id === worldFilter)) {
      for (const c of store.listCharacters(w.id)) {
        const hash = c.appearance?.spriteAsset;
        if (!hash) continue; // 仙子等无立绘跳过
        if (c.appearance.anchors && !force) {
          results.push({ id: c.id, name: c.name, skipped: 'has anchors' });
          continue;
        }
        const blob = store.getAsset(hash);
        if (!blob) {
          results.push({ id: c.id, name: c.name, skipped: 'asset missing' });
          continue;
        }
        const anchors = await detectCharacterAnchors(adapters.anchors, blob);
        if (!anchors) {
          results.push({ id: c.id, name: c.name, skipped: 'decode failed' });
          continue;
        }
        c.appearance.anchors = anchors;
        store.saveCharacter(c);
        results.push({ id: c.id, name: c.name, source: anchors.source });
      }
    }
    return { count: results.length, detected: results.filter((r) => r.source).length, results };
  });

  // 管理端点：存量角色体型「回填」。老角色 appearance.scale 恒 1.0（体型特性上线前造的），
  // 这里用 LLM 从 visualDescription 判体型（small/medium/big）→ sizeToScale 写回 appearance.scale，
  // 让存量角色也有高矮差异。跳过仙子（客户端仙子恒 FAIRY_HEIGHT，scale 无意义）。
  // 默认只改「未标定」的（scale≈1.0）；?force=1 全量重标；?world=<id> 限单个世界。
  // 客户端下次进场（scene_entered 带 appearance.scale）即生效。必须配 MALIANG_ADMIN_TOKEN。
  app.post<{ Querystring: { world?: string; force?: string } }>('/admin/calibrate-size', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const worldFilter = req.query.world;
    const force = req.query.force === '1';
    const results: { id: string; name: string; size?: string; scale?: number; skipped?: string }[] = [];
    for (const w of store.listWorlds().filter((x) => !worldFilter || x.id === worldFilter)) {
      for (const c of store.listCharacters(w.id)) {
        if (c.isFairy) { // 仙子客户端恒 FAIRY_HEIGHT，回填无意义
          results.push({ id: c.id, name: c.name, skipped: 'fairy' });
          continue;
        }
        const desc = c.appearance?.visualDescription;
        if (!desc) {
          results.push({ id: c.id, name: c.name, skipped: 'no description' });
          continue;
        }
        // 已标定 → 跳过（非 force）。判据：显式 appearance.size 标记（含 medium，重跑幂等），
        // 或旧数据的 scale 明显偏离 1.0（标记位上线前回填的 non-medium 仍认得，不重复处理）。
        // 唯一漏网：标记位上线前回填的 medium（scale=1.0 无标记）会被再处理一次——补上标记后即永久粘住。
        if (!force && (c.appearance.size || Math.abs((c.appearance.scale ?? 1.0) - 1.0) > 0.01)) {
          results.push({ id: c.id, name: c.name, skipped: 'already calibrated' });
          continue;
        }
        const size = await adapters.llm.classifyCreatureSize(desc);
        const scale = sizeToScale(size);
        c.appearance.scale = scale;
        c.appearance.size = size; // 落标记位：下次重跑认得已标定（含 medium）
        store.saveCharacter(c);
        results.push({ id: c.id, name: c.name, size, scale });
      }
    }
    return {
      count: results.length,
      calibrated: results.filter((r) => r.size).length,
      results,
    };
  });

  // 管理端点：存量角色立绘「原地裁边」。把已存立绘裁到贴身盒（trimToContent）重新入库，
  // 角色 spriteAsset 指向裁后新 hash，并重触发 idle 动画重生成（用新默认 cellH=256）。
  // 只裁透明边、不重新生图 → 不改小朋友认得的形象。裁后立绘更贴身 → Seedance idle 取景更好。
  // ?world=<id> 限定单个世界；缺省全世界。已贴身的立绘（无可裁）跳过动画重生成免重复烧钱。
  // 必须配 MALIANG_ADMIN_TOKEN。
  app.post<{ Querystring: { world?: string } }>('/admin/retrim-sprites', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const worldFilter = req.query.world;
    const worlds = store.listWorlds().filter((w) => !worldFilter || w.id === worldFilter);
    const characters: { id: string; name: string; prev: string; spriteAsset: string; changed: boolean }[] = [];
    const regenTriggered = new Set<string>();
    for (const w of worlds) {
      for (const c of store.listCharacters(w.id)) {
        const prev = c.appearance?.spriteAsset;
        if (!prev) continue; // 仙子等无立绘（用本地图集）跳过
        const blob = store.getAsset(prev);
        if (!blob) continue;
        const hash = store.putAsset(trimToContent(blob));
        const changed = hash !== prev;
        if (changed) {
          c.appearance.spriteAsset = hash;
          store.saveCharacter(c);
          // 裁后是全新 hash（无动画记录）→ 触发一次按新分辨率重生成
          if (!regenTriggered.has(hash)) {
            regenTriggered.add(hash);
            triggerCharacterAnimation(adapters, store, hash, toSpriteSheet);
          }
        }
        characters.push({ id: c.id, name: c.name, prev, spriteAsset: hash, changed });
      }
    }
    return { count: characters.length, regenerated: regenTriggered.size, characters };
  });

  // onboarding 玩家形象：描述（由问题答案拼装）→ 生图 → 资产 hash。不建角色——
  // 玩家档案在设备端，资产内容寻址共享。描述过文字审核（防客户端篡改）。
  app.post<{ Body: { visualDescription?: string } | null }>('/player-sprite', async (req, reply) => {
    const desc = (req.body?.visualDescription ?? '').trim();
    if (desc.length === 0) return reply.code(400).send({ error: 'visualDescription required' });
    const check = await adapters.moderation.moderateText(desc);
    if (!check.allowed) return reply.code(400).send({ error: 'moderation blocked' });
    const gen = await generateSprite(adapters, desc, store);
    // 试点：玩家形象静态先返回，idle 动画后台异步补（客户端凭 spriteAsset 轮询 /sprite-anim/:hash）
    triggerCharacterAnimation(adapters, store, gen.hash, toSpriteSheet);
    // anchors 随返回体进设备档案（玩家档案在 user://profile.json，服务端够不着，见设计 §2.3）
    return { spriteAsset: gen.hash, anchors: gen.anchors ?? undefined };
  });

  // 存量玩家档案补算锚点（设计 §2.3）：老档案只有 spriteAsset 没有 anchors，客户端发现缺失时
  // 按 hash 现算一次并自行落档。开放路由（同 /assets 哲学：hash 内容寻址、只读不改状态、
  // 每 hash 一次 vision 调用成本可忽略）。资产不存在 404。
  app.post<{ Body: { spriteAsset?: string } | null }>('/player-sprite/anchors', async (req, reply) => {
    const hash = (req.body?.spriteAsset ?? '').trim();
    if (hash.length === 0) return reply.code(400).send({ error: 'spriteAsset required' });
    const blob = store.getAsset(hash);
    if (!blob) return reply.code(404).send({ error: 'asset not found' });
    const anchors = await detectCharacterAnchors(adapters.anchors, blob);
    if (!anchors) return reply.code(422).send({ error: 'asset not decodable' });
    return { spriteAsset: hash, anchors };
  });

  // onboarding 自我介绍：客户端端侧识别好的转写 → LLM 提取名字/称呼 → TTS 复述确认音频。
  // 提取不到名字返回空串，客户端播预制 retry 重问（多轮）。识别一律在端侧完成，本路由只收文本。
  app.post<{
    Body: { transcript?: string } | null;
  }>('/onboarding/intro', async (req) => {
    const transcript = (req.body?.transcript ?? '').trim();
    if (transcript.length === 0) return { transcript: '', name: '', nickname: '' };
    const prof = await adapters.llm.extractProfile(transcript);
    if (!prof.name && !prof.nickname) return { transcript, name: '', nickname: '' };
    const callName = prof.nickname || prof.name;
    const audio = await adapters.tts.synthesize(`你叫${callName}，对不对呀？`, 'lovely_girl');
    const hash = store.putAsset(audio);
    return {
      transcript,
      name: prof.name,
      nickname: prof.nickname,
      confirmTtsAsset: hash,
      confirmMime: audio.mime,
    };
  });

  // SDF 可动物件：描述 → LLM 设计 spec（~15 行 JSON）→ 服务端校验 → 下发。
  // 客户端 SdfProp.from_spec 再做一次同规则校验（防传输/版本偏差），双保险。
  app.post<{ Body: { description?: string } | null }>('/sdf-props', async (req, reply) => {
    const desc = (req.body?.description ?? '').trim();
    if (desc.length === 0) return reply.code(400).send({ error: 'description required' });
    const check = await adapters.moderation.moderateText(desc);
    if (!check.allowed) return reply.code(400).send({ error: 'moderation blocked' });
    const spec = await adapters.llm.designSdfProp(desc);
    const validated = validateSdfPropSpec(spec);
    if (!validated.ok) return reply.code(502).send({ error: `spec invalid: ${validated.error}` });
    return { spec: validated.spec };
  });

  // 取生成的 sprite 资源。
  //
  // 内容寻址 = URL 里的 hash 就是内容的 SHA-256 摘要，同一个 URL 的字节永远不可能变——
  // 内容变了 hash 就变了，URL 也跟着变。所以这里可以放心地 immutable + 一年 max-age，
  // 不存在缓存陈旧的风险。ETag 直接用 hash（它本来就是摘要），命中就回 304 连字节都不用传。
  //
  // Godot 客户端因为自己有 user://asset_cache（同样按 hash 存、永不失效）本来就不重复拉，
  // 这组头是给管理台、浏览器、以及将来任何 CDN / 反代用的。
  app.get<{ Params: { hash: string } }>('/assets/:hash', async (req, reply) => {
    const asset = store.getAsset(req.params.hash);
    if (!asset) return reply.code(404).send({ error: 'asset not found' });
    const etag = `"${req.params.hash}"`;
    reply.header('cache-control', 'public, max-age=31536000, immutable').header('etag', etag);
    if (etagMatches(req.headers['if-none-match'], etag)) return reply.code(304).send();
    return reply.header('content-type', asset.mime).send(Buffer.from(asset.bytes));
  });

  // 立绘 idle 动画状态轮询：客户端拿到静态 spriteAsset 后轮询本路由，
  // status=ready 时取 animAsset（图集，走 /assets/:hash）+ meta（cols/rows/fps…）切动画。
  // 无记录返回 none（未触发/不在试点范围）；pending 生成中；failed 保留静态。
  app.get<{ Params: { hash: string } }>('/sprite-anim/:hash', async (req) => {
    const rec = store.getSpriteAnim(req.params.hash);
    return rec ?? { status: 'none' };
  });

  // 管理端点：直接上传一张预生成的 idle 图集并绑定到某立绘 hash（不重新跑生成管线）。
  // 用于把线下已确认好的动画上线（如仙子），或用同一张立绘复用现成动画——避免烧钱重生成、
  // 且静态形象完全不变。烧钱/改小朋友所见——必须配 MALIANG_ADMIN_TOKEN。
  app.post<{
    Params: { hash: string };
    Body: { animPngBase64?: string; meta?: SpriteSheetMeta } | null;
  }>('/admin/sprite-anim/:hash', { bodyLimit: 16 * 1024 * 1024 }, async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const b64 = req.body?.animPngBase64;
    const meta = req.body?.meta;
    if (!b64 || !meta) return reply.code(400).send({ error: 'animPngBase64 and meta required' });
    const ok =
      meta.cols > 0 && meta.rows > 0 && meta.frameCount > 0 &&
      meta.fps > 0 && meta.cellW > 0 && meta.cellH > 0 &&
      meta.frameCount <= meta.cols * meta.rows;
    if (!ok) return reply.code(400).send({ error: 'invalid meta' });
    const bytes = Uint8Array.from(Buffer.from(b64, 'base64'));
    const animAsset = store.putAsset({ bytes, mime: sniffImageMime(bytes) });
    store.setSpriteAnimReady(req.params.hash, animAsset, meta);
    return { spriteHash: req.params.hash, animAsset, meta, status: 'ready' };
  });

  // 管理端点：主动触发线上生成 idle 图集（Seedance→图集→入库整条管线原样跑），与上面的
  // 本地上传互补——存量立绘不用线下跑好再传，直接让线上补。烧钱——必须配 MALIANG_ADMIN_TOKEN。
  // 幂等：pending 一律不打断（防同 hash 并发双跑烧钱）；已 ready 默认跳过，?force=true 强制重生成。
  // fire-and-forget：立即返回，之后照旧轮询 GET /sprite-anim/:hash 等 ready。
  app.post<{
    Params: { hash: string };
    Querystring: { force?: string };
  }>('/admin/sprite-anim/:hash/generate', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    if (!store.getAsset(req.params.hash)) {
      return reply.code(404).send({ error: 'sprite asset not found' });
    }
    const force = req.query.force === 'true' || req.query.force === '1';
    const existing = store.getSpriteAnim(req.params.hash);
    if (existing?.status === 'pending' || (existing?.status === 'ready' && !force)) {
      return { spriteHash: req.params.hash, status: existing.status, triggered: false };
    }
    void generateCharacterAnimation(adapters, store, req.params.hash, toSpriteSheet);
    return { spriteHash: req.params.hash, status: 'pending', triggered: true };
  });

  // 从已存原片重打图集：不碰视频生成 = 零成本。
  //
  // 用法：想换图集参数（例如把抽帧从 8fps 提到原片的原生帧率、或改 cellH）时，改
  // sprite_sheet.ts 的默认值 → 部署 → 打这个端点。三段原片是生成当时一并入库的
  // （SpriteAnimRecord.clipVideos），所以重打是纯本地 ffmpeg，不用重新向 Seedance 买。
  // 刻意不开放 fps/cellH 查询参数：参数只有一个来源（代码里的默认值），否则线上会出现
  // 一批「用某次请求的临时参数打出来的」图集，谁也说不清它是按什么打的。
  //
  // 没有原片（v1 老记录）→ 409，调用方该走 /generate（要花钱）。
  app.post<{ Params: { hash: string } }>('/admin/sprite-anim/:hash/repack', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const ok = await repackFromStoredClips(store, req.params.hash, toSpriteSheet);
    if (!ok) {
      return reply.code(409).send({ error: 'no stored clip videos; use /generate instead' });
    }
    const rec = store.getSpriteAnim(req.params.hash);
    return { spriteHash: req.params.hash, animAsset: rec?.animAsset, meta: rec?.meta };
  });

  // 批量重打：遍历所有存有原片的立绘，逐个 repack。串行（ffmpeg 吃 CPU，并发会把容器压垮）。
  // fire-and-forget：立即返回待处理条数，进度看日志。
  app.post('/admin/sprite-anim/repack-all', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    const hashes = store.listSpriteAnimsWithClips();
    void (async () => {
      let done = 0;
      for (const h of hashes) {
        try {
          if (await repackFromStoredClips(store, h, toSpriteSheet)) done++;
        } catch (err) {
          console.warn(`repack 失败 sprite=${h}:`, err instanceof Error ? err.message : err);
        }
      }
      console.log(`repack-all 完成：${done}/${hashes.length}`);
    })();
    return { pending: hashes.length };
  });

  // 只读状态后台（P6）：/debug/state 出 JSON 全量快照，/debug 出单页 dashboard 渲染它。
  // 只读直连 WorldStore，不改状态。含玩家名/记忆等，配了 MALIANG_ADMIN_TOKEN 就要 ?token= 或 x-admin-token。
  const debugToken = process.env.MALIANG_ADMIN_TOKEN;
  const debugAuthed = (req: { headers: Record<string, unknown>; query: unknown }): boolean => {
    if (!debugToken) return true; // 未配置 token = 开发环境，开放
    const q = (req.query as { token?: string } | undefined)?.token;
    return req.headers['x-admin-token'] === debugToken || q === debugToken;
  };
  app.get('/debug/state', async (req, reply) => {
    if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    return buildDebugState(store);
  });
  // 资源化只读 API（/debug/api/*）：React 多页面后台分资源拉取（见 debug_api.ts）。
  registerDebugApi(app, store, debugAuthed);

  // ── 全量数据备份 / 恢复 ──
  // 数据只有持久卷一个落点，卷没了就全没了；这两个端点是唯一的兜底。
  //
  // 门禁刻意比 debugAuthed 更严：debugAuthed 在**未配** MALIANG_ADMIN_TOKEN 时一律放行
  //（"开发环境开放"），但导出 = 全量数据出境、导入 = 全量数据被覆盖。真要是哪天生产漏配了
  // token，那条规则等于把删库按钮挂在公网上。所以没 token 就直接关掉这两个端点。
  const backupAuthed = (req: { headers: Record<string, unknown>; query: unknown }): boolean =>
    Boolean(debugToken) && debugAuthed(req);

  app.get('/admin/backup', async (req, reply) => {
    if (!backupAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    let out: BackupExport;
    try {
      out = startBackup(store);
    } catch (e) {
      return reply.code(500).send({ error: (e as Error).message });
    }
    // manifest 走响应头：管理台不用解包就能显示"这一包里有多少玩家/角色/资产"。
    return reply
      .header('content-type', 'application/gzip')
      .header('content-disposition', `attachment; filename="${out.filename}"`)
      .header('x-backup-manifest', JSON.stringify(out.manifest))
      .send(out.stream);
  });

  // 库体检（只读）：死资产引用 + benchmark 众包样本。
  // 死引用 = 库里记着某张立绘、资产库里却没有 → 客户端会一直拿 404。
  app.get('/admin/integrity', async (req, reply) => {
    if (!backupAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    return {
      deadSpriteRefs: store.listDeadSpriteRefs(),
      deviceSamples: store.listDeviceSamples(),
    };
  });

  // 清理。**默认 dry-run**——不带 apply=true 只报告将要改什么，一个字节都不动。
  // 这样误调一次不会毁数据；真要动手必须显式 apply。
  app.post<{
    Querystring: { apply?: string };
    Body: { deviceSamples?: { gpu: string; deviceId: string }[] } | null;
  }>('/admin/integrity/fix', async (req, reply) => {
    if (!backupAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    const apply = req.query.apply === 'true' || req.query.apply === '1';
    const deadRefs = store.listDeadSpriteRefs();
    // 要删哪些 benchmark 样本由调用方点名（别在服务端猜"哪条像测试数据"，猜错就是删真数据）
    const toDelete = req.body?.deviceSamples ?? [];

    if (!apply) {
      return { dryRun: true, wouldClearSpriteRefs: deadRefs, wouldDeleteDeviceSamples: toDelete };
    }
    const cleared = store.clearDeadSpriteRefs();
    let deleted = 0;
    for (const d of toDelete) deleted += store.deleteDeviceSample(d.gpu, d.deviceId);
    app.log.warn({ cleared, deleted }, 'integrity fix applied — 生产库已被清理');
    return { dryRun: false, clearedSpriteRefs: cleared, deletedDeviceSamples: deleted, details: deadRefs };
  });

  // 上传的备份包直接流式落到磁盘临时文件，不进内存——fastify 默认只认 json/urlencoded，
  // 且默认 bodyLimit 只有 1MB，几十 MB 的包必须走自定义 parser 才不会被顶回来。
  app.addContentTypeParser('application/gzip', (_req, payload, done) => {
    const tarPath = path.join(os.tmpdir(), `maliang-restore-${randomUUID()}.tar.gz`);
    const ws = createWriteStream(tarPath);
    let size = 0;
    payload.on('data', (c: Buffer) => {
      size += c.length;
      if (size > MAX_RESTORE_UPLOAD) payload.destroy(new Error('备份包过大'));
    });
    pipeline(payload, ws, (err) => {
      if (err) {
        rmSync(tarPath, { force: true });
        done(err);
        return;
      }
      done(null, { tarPath });
    });
  });

  // 全量数据导入：**破坏性**，当前数据会被整个换掉。restoreBackup 内部保证——
  // 包坏了在校验阶段就失败（现网数据没动过），且覆盖前会先把当前数据另存一份兜底包。
  app.post('/admin/restore', async (req, reply) => {
    if (!backupAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    const tarPath = (req.body as { tarPath?: string } | undefined)?.tarPath;
    if (!tarPath) {
      return reply.code(400).send({ error: '请以 content-type: application/gzip 上传 .tar.gz 备份包' });
    }
    try {
      const res = await restoreBackup(store, tarPath);
      app.log.warn(
        { manifest: res.manifest, preRestoreBackup: res.preRestoreBackup },
        'data restored from backup — 现网数据已被整体替换',
      );
      return { ok: true, manifest: res.manifest, preRestoreBackup: res.preRestoreBackup };
    } catch (e) {
      return reply.code(400).send({ error: (e as Error).message });
    } finally {
      rmSync(tarPath, { force: true });
    }
  });
  // /debug 页面：优先托管 admin/dist（React 多页面管理台，Docker 多阶段构建产出）。
  // HTML/JS 是公开壳子不含数据（数据全在带门禁的 /debug/api/*），页面本身不设 token 门——
  // 打开后 SPA 里粘 token 即可用（也兼容 ?token= 透传）。未构建（本地测试）回退旧版内嵌单页。
  const adminDist = path.join(import.meta.dirname, '..', 'admin', 'dist');
  if (existsSync(path.join(adminDist, 'index.html'))) {
    await app.register(fastifyStatic, { root: adminDist, prefix: '/debug/' });
    app.get('/debug', async (_req, reply) => reply.sendFile('index.html'));
  } else {
    app.get('/debug', async (req, reply) => {
      if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
      return reply.header('content-type', 'text/html; charset=utf-8').send(DEBUG_DASHBOARD_HTML);
    });
  }

  // 引导式造角色图标（P3）：GET 看当前映射；POST 批量生成（幂等，?force=1 全量重生）。
  // 与 /debug 同一 admin token 门禁。生成走服务端的 image adapter（prod 有真 key）。
  app.get('/admin/creation-icons', async (req, reply) => {
    if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    return { icons: store.listCreationIcons() };
  });
  app.post<{ Querystring: { force?: string; only?: string } }>('/admin/creation-icons', async (req, reply) => {
    if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    const force = req.query.force === '1' || req.query.force === 'true';
    const only = (req.query.only ?? '').split(',').map((s) => s.trim()).filter(Boolean);
    const result = await generateCreationIcons(adapters, store, { force, only });
    return { ...result, icons: store.listCreationIcons() };
  });

  // 物品实体外观缩略图：GET 看当前映射；POST 由客户端上传单张 PNG。物品在服务端没有图片
  //（全靠客户端按 renderRef 现场渲染 glTF/SDF/贴纸），所以 debug 后台看物品长什么样，得让
  // 客户端把每个 ItemDef 渲染成 PNG 再传上来 → putAsset（内容寻址）→ setItemIcon 绑到 id。
  // 与 /admin/creation-icons（服务端生图）互补，这是客户端→服务端的反向通路，同一 debugAuthed
  // 门禁（本地无 token 开放、生产带 token）。id 必须是已知实体（内置或某世界造物），防落孤儿图标。
  app.get('/admin/item-icons', async (req, reply) => {
    if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    return { icons: store.listItemIcons() };
  });
  app.post<{
    Params: { id: string };
    Body: { pngBase64?: string } | null;
  }>('/admin/item-icon/:id', { bodyLimit: 8 * 1024 * 1024 }, async (req, reply) => {
    if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
    const itemId = req.params.id;
    // id 合法性：内置常量，或任一世界的造物行
    const known =
      !!getBuiltinItem(itemId) ||
      store.listWorlds().some((w) => store.listWorldItems(w.id).some((d) => d.id === itemId));
    if (!known) return reply.code(404).send({ error: 'unknown item id' });
    const b64 = req.body?.pngBase64;
    if (!b64) return reply.code(400).send({ error: 'pngBase64 required' });
    const bytes = Uint8Array.from(Buffer.from(b64, 'base64'));
    if (bytes.length === 0) return reply.code(400).send({ error: 'empty image' });
    const iconAsset = store.putAsset({ bytes, mime: sniffImageMime(bytes) });
    store.setItemIcon(itemId, iconAsset);
    return { itemId, iconAsset };
  });

  // 森林村民种入（forest-inhabitants P3）：按 FOREST_CHARACTER_SEEDS 走生图管线落库
  // sceneId=forest。幂等（同名跳过）；?only=名字,名字 限定只种指定角色。生图烧钱，admin token 门禁。
  app.post<{ Params: { id: string }; Querystring: { only?: string } }>(
    '/admin/worlds/:id/seed-forest',
    async (req, reply) => {
      if (!debugAuthed(req)) return reply.code(403).send({ error: 'admin token required' });
      if (!store.getWorld(req.params.id)) return reply.code(404).send({ error: 'world not found' });
      const only = (req.query.only ?? '').split(',').map((s) => s.trim()).filter(Boolean);
      return seedForestCharacters(adapters, store, req.params.id, { only, toSpriteSheet });
    },
  );

  // 昂贵操作限流：每连接 N/分钟 + 全局并发上限（防刷付费 API）
  const limiter = new RateLimiter(
    Number(process.env.RATE_PER_MIN ?? 8),
    Number(process.env.RATE_GLOBAL_MAX ?? 4),
  );

  // 多人基座：world 维度的连接注册表（world_info 登记，leave_world/close 摘除）+ 演出调度台
  const hub = new WorldHub();

  // 地形 tile 编辑（scene-items）：唯一写入口 editSceneTerrain——校验 → version+1 →
  // terrain_patch 广播给同世界在场客户端。admin token 门禁（后续玩法意图也走同一函数）。
  app.post<{
    Params: { wid: string; sid: string };
    Body: { edits?: TileEditInput[] } | null;
  }>('/admin/worlds/:wid/scenes/:sid/tile-edits', async (req, reply) => {
    const token = process.env.MALIANG_ADMIN_TOKEN;
    if (!token || req.headers['x-admin-token'] !== token) {
      return reply.code(403).send({ error: 'admin token required' });
    }
    if (!store.getWorld(req.params.wid)) return reply.code(404).send({ error: 'world not found' });
    const edits = req.body?.edits;
    if (!Array.isArray(edits) || edits.length === 0) return reply.code(400).send({ error: 'edits required' });
    try {
      const r = editSceneTerrain(store, hub, req.params.wid, req.params.sid, edits);
      return { version: r.version, applied: r.applied.length, paletteAppend: r.paletteAppend };
    } catch (e) {
      if (e instanceof TerrainEditError) return reply.code(400).send({ error: e.message });
      throw e;
    }
  });
  // 剧本造物：prop.create(desc) 走造物管线出 spec 并落 items 实体行（sdf_inline，不进矩阵
  // 不占 tile——演出指令流照旧客户端临时渲染，演完即散），不扣小红花（非付费造角色）。
  // 审核挡/校验败/异常一律返回 null，execCommand 侧转 stage_abort。
  const makeStageProp: StagePropMaker = async (worldId, desc) => {
    try {
      const check = await adapters.moderation.moderateText(desc);
      if (!check.allowed) return null;
      const spec = await adapters.llm.designSdfProp(desc);
      const validated = validateSdfPropSpec(spec);
      if (!validated.ok) return null;
      const def = creationItemDef(worldId, randomUUID(), validated.spec);
      store.upsertItem(def);
      return { id: def.id, spec: validated.spec };
    } catch {
      return null;
    }
  };
  // 全局并发演出上限(worker 内存/线程防线):环境变量 MAX_CONCURRENT_STAGES 覆盖缺省。
  const maxStages = Number(process.env.MAX_CONCURRENT_STAGES) || DEFAULT_MAX_CONCURRENT_STAGES;
  const stages = new StageDirector(hub, makeStageProp, maxStages);

  // 管理端点：拿一个手写剧本在指定世界开演（试演/真机验收用；Plan 2 上线后由语音意图触发）。
  // 演出广播给世界里所有连接，孩子的平板会直接进观演态——所以世界里得先有人。
  app.post<{ Params: { id: string }; Body: { screenplay?: string; sceneId?: string } | null }>(
    '/admin/worlds/:id/stage',
    async (req, reply) => {
      const token = process.env.MALIANG_ADMIN_TOKEN;
      if (!token || req.headers['x-admin-token'] !== token) {
        return reply.code(403).send({ error: 'admin token required' });
      }
      if (!store.getWorld(req.params.id)) return reply.code(404).send({ error: 'world not found' });
      const name = req.body?.screenplay ?? '';
      if (!(SCREENPLAYS as readonly string[]).includes(name)) {
        return reply.code(400).send({ error: `screenplay must be one of ${SCREENPLAYS.join(', ')}` });
      }
      if (stages.activeIn(req.params.id)) return reply.code(409).send({ error: '这个世界正在演出' });
      // 全局并发上限:太多世界在演出就先拒(503),别把 worker 撑爆。前端可提示「稍等再玩」。
      if (stages.atCapacity()) return reply.code(503).send({ error: '同时演出太多了，稍等一下再开演' });
      let opts: StageStartOpts;
      try {
        opts = buildDebut(store, hub, req.params.id, name as ScreenplayName, req.body?.sceneId);
      } catch (e) {
        if (e instanceof DebutError) return reply.code(400).send({ error: e.message });
        throw e;
      }
      const run = stages.startStage(req.params.id, opts);
      if (!run) return reply.code(409).send({ error: '这个世界正在演出' });
      // 不 await 终局：演出要演几分钟，HTTP 只回「开演了，演员是这些」。
      void run.catch(() => {});
      return { id: req.params.id, screenplay: name, actors: opts.actors, params: opts.params };
    },
  );

  // WebSocket：造角色请求 → 进度推送 → 完成/失败
  app.get('/ws', { websocket: true }, (socket, req) => {
    const connKey = randomUUID(); // 每连接一个限流 key
    const session = newVoiceSession(); // 边录边传：本连接的语音分片缓冲
    // 能力协商：客户端自带 TTS（edge-tts）时连接 URL 带 ?clientTts=1，本连接全程跳过服务端合成。
    const q = req.query as { clientTts?: string; posbin?: string } | undefined;
    session.clientTts = q?.clientTts === '1';
    // 位置流二进制：客户端 ?posbin=1 声明，服务端据此对本连接收发二进制位置流；回执经 world_state.posBin。
    session.posBin = q?.posbin === '1';
    // 连接层设备信息（activity 快照的服务端半段）：muvee 是反代，真实 IP 在 x-forwarded-for。
    session.connIp = clientIp(req);
    const ua = req.headers['user-agent'];
    if (typeof ua === 'string' && ua) session.connUa = ua.slice(0, 512);
    socket.on('message', (raw: Buffer, isBinary?: boolean) => {
      session.lastSeenMs = Date.now(); // 二进制帧也算活跃(不进 handleWsMessage 就不会刷新)
      // 二进制帧 = 位置流(唯一二进制上行);其余全走 JSON 文本。首字节 tag 兜底校验。
      if (isBinary && raw.length > 0 && raw[0] === POS_TAG_REPORT) {
        try {
          const d = decodeReport(raw);
          // worldId 不在二进制帧里:位置流只发生在 world_info 入 hub 之后,由 hub 决定归属。
          applyPositionsReport({ worldId: hub?.worldOf(connKey) ?? '', sceneId: d.sceneId, t: d.t, chars: d.chars, player: d.player }, socket, store, session, connKey, hub, stages);
        } catch (e) {
          app.log.warn(`[posbin] 解码位置流失败: ${e instanceof Error ? e.message : String(e)}`);
        }
        return;
      }
      void handleWsMessage(socket, raw.toString(), adapters, store, limiter, connKey, session, hub, stages);
    });
    // 心跳空闲扫描：新客户端会发 ping 刷新 lastSeen；超时无任何消息即判半开连接，
    // terminate 触发下面的 close 处理清 hub 幽灵（含 host 重选）+ 释限流位。老客户端永不误杀（见 isConnectionDead）。
    const heartbeatSweep = setInterval(() => {
      if (isConnectionDead(session, Date.now())) {
        app.log.info(`[hb] 连接 ${connKey.slice(0, 8)} 心跳超时，断开`);
        socket.terminate();
      }
    }, HEARTBEAT_SWEEP_MS);
    heartbeatSweep.unref?.(); // 不因这个定时器阻止进程优雅退出
    // 连接断开时 flush 会话记忆兜底（前端没发 leave_world 就掉线）
    socket.on('close', () => {
      clearInterval(heartbeatSweep);
      notifyHubLeave(hub, connKey, stages, session.playerId);
      void endSessionVisit(session, adapters, store, Date.now());
    });
  });

  // 存量回填：把造角色流程上线前预种的村民补上 idle 动画（fire-and-forget，只在真实进程开，不阻塞启动）。
  if (deps.backfillOnBoot) {
    const n = backfillCharacterAnimations(adapters, store, toSpriteSheet);
    if (n > 0) app.log.info(`idle 动画存量回填：触发 ${n} 个角色`);
    // 音色回填：voiceId 不在 edge 目录里的老角色按 id 稳定哈希落主力池，仙子固定 Xiaoyi（幂等，同步很快）。
    const nv = backfillVoices(store);
    if (nv > 0) app.log.info(`音色存量回填：改写 ${nv} 个角色`);
  }

  return app;
}

/**
 * 进行中的会话（Visit）在连接上的状态：pending 累积各角色的对话增量，
 * 会话结束（leave_world / socket.close）或单角色超阈值时 flush 批量抽记忆。
 */
export interface VisitState {
  id: number; // visits 表行 id
  worldId: string;
  playerId: string;
  pending: Map<string, { child: string; npc: string }[]>; // characterId → 尚未抽取的对话增量
  // characterId → 本段 Visit 与该角色的完整对话（不随中途 flush 清空）。整段回喂 routeIntent：
  // session 内上下文完整、不截尾；Visit 结束即弃，重进世界从零开始（长期记忆走 memories）。
  history: Map<string, ChatTurn[]>;
  // characterId → 超长压缩的摘要（history 只留近尾，更早轮次折叠在这里）
  summary: Map<string, string>;
  // 正在后台压缩的角色（防同一角色并发压两次）
  compacting: Set<string>;
}

/** 当前 Visit 里与某角色的 session 上下文：完整对话 + 超长压缩摘要（无 Visit/首轮 → 空=全新 session）。 */
export function visitContext(session: VoiceSession, characterId: string): { history: ChatTurn[]; summary?: string } {
  return {
    history: session.visit?.history.get(characterId) ?? [],
    summary: session.visit?.summary.get(characterId),
  };
}

/** session 压缩阈值：history+摘要总字数超过即触发（中文≈1字/token，200k 字≈200k token 上下文）。 */
const SESSION_COMPACT_CHARS = Number(process.env.SESSION_COMPACT_CHARS ?? 200_000);
/** 压缩后保留的最近条数（child+npc 各算一条，10 条=5 个来回），更早的折叠进摘要。 */
const COMPACT_KEEP_TAIL = 10;

/**
 * session 上下文超阈值时后台压缩一轮：较旧轮次（并入上次摘要）→ compactSession 出新摘要，
 * history 原地只留近尾。失败只影响这次压缩（下轮再试），绝不影响对话回复。
 */
export async function maybeCompactVisit(
  session: VoiceSession,
  characterId: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  threshold = SESSION_COMPACT_CHARS,
): Promise<void> {
  const visit = session.visit;
  if (!visit || visit.compacting.has(characterId)) return;
  const hist = visit.history.get(characterId);
  if (!hist || hist.length <= COMPACT_KEEP_TAIL) return;
  const prev = visit.summary.get(characterId) ?? '';
  const total = prev.length + hist.reduce((n, t) => n + t.text.length, 0);
  if (total <= threshold) return;
  const cut = hist.length - COMPACT_KEEP_TAIL;
  const older = hist.slice(0, cut);
  visit.compacting.add(characterId);
  try {
    const character = store.getCharacter(visit.worldId, characterId);
    const summary = await adapters.llm.compactSession({
      characterName: character?.name ?? '',
      personality: character?.personality ?? '',
      previousSummary: prev || undefined,
      turns: older,
    });
    if (summary) visit.summary.set(characterId, summary);
    hist.splice(0, cut); // 原地删已压缩的旧轮次（await 期间新 push 的仍在尾部，不丢）
  } catch (err) {
    console.warn(`session 压缩失败（下轮再试，不影响对话）：${String(err)}`);
  } finally {
    visit.compacting.delete(characterId);
  }
}

/**
 * 单连接语音会话。识别一律在客户端端侧完成（Android 插件 / macOS GDExtension 的 sherpa），
 * 服务端只收 voice_transcript 的成品文本——服务端 ASR 已整条退役，不再有边说边识别的音频会话。
 */
export interface VoiceSession {
  worldId: string;
  characterId: string;
  /** 当前玩家 id（设备端稳定 UUID，随消息上报）：供记忆/Visit 按玩家归属（P3/P4 消费）。 */
  playerId: string;
  /** 进行中的会话（world_info 起、leave_world/close 收尾）；每轮对话增量累积其中，结束批量抽记忆。 */
  visit: VisitState | null;
  /** 进行中的引导式造角色会话（对小仙子说造角色即开启）；期间语音/点选都当造角色答复，见 advanceCreation。 */
  creation: CreationState | null;
  /** 客户端自带 TTS（edge-tts 直连微软）：WS 连接 URL 带 ?clientTts=1 时置位，服务端全程跳过合成只发文本+voiceId。 */
  clientTts: boolean;
  /** 位置流二进制帧：客户端连接 URL 带 ?posbin=1 时置位。收发高频位置流走二进制(见 pos_codec)，老客户端留 JSON。 */
  posBin: boolean;
  /** 连接层设备信息（activity 快照的服务端半段）：握手时从 req 取，world_info 建 Visit 时并入。 */
  connIp?: string;
  connUa?: string;
  /**
   * 玩家当前所在场景（模型 B）。world_info 进世界时置初值，enter_scene 走 portal 时更新。
   * getLocations/委托候选/角色物件下发都按它过滤（消化「委托指向别场景」的边界）。
   */
  currentScene: string;
  /** 心跳：上次收到本连接任意消息的时刻（ms）。空闲扫描据此判半开连接。 */
  lastSeenMs: number;
  /**
   * 本连接是否证明过会发 app 层 ping（新客户端）。
   * 只对 pingCapable 的连接做「超时即断」——老客户端不发 ping、静止时零流量，
   * 绝不能被误判为死连接踢掉（它们也没自动重连兜底）。
   */
  pingCapable: boolean;
}

export function newVoiceSession(): VoiceSession {
  return { worldId: '', characterId: '', playerId: '', visit: null, creation: null, clientTts: false, posBin: false, currentScene: DEFAULT_SCENE, lastSeenMs: Date.now(), pingCapable: false };
}

/** 服务端 ASR 退役后被废弃的 WS 消息类型：收到即静默丢弃（见 handleWsMessage 末尾）。 */
const RETIRED_VOICE_TYPES = new Set(['voice_input', 'voice_start', 'voice_chunk', 'voice_end', 'voice_cancel']);

/** 心跳：多久没任何消息判半开连接（三个客户端 ping 周期）。 */
export const HEARTBEAT_TIMEOUT_MS = 30_000;
/** 心跳：连接层扫描间隔。 */
export const HEARTBEAT_SWEEP_MS = 10_000;

/**
 * 半开连接判定（抽出供单测）：仅对证明过会发 ping 的新客户端做超时判死。
 * 老客户端不发 ping（pingCapable=false）、静止时零流量，绝不能被误杀——它们没自动重连兜底，
 * 一旦被踢就彻底掉线卡住。真实死连接仍由 TCP close 走原有 close 处理清理，与本判定无关。
 */
export function isConnectionDead(session: VoiceSession, now: number): boolean {
  return session.pingCapable && now - session.lastSeenMs > HEARTBEAT_TIMEOUT_MS;
}

const VISIT_FLUSH_THRESHOLD = 20; // 单角色累积超此轮数即中途 flush，兜底长会话掉线全丢

/** 进世界：开一段 Visit。已有旧 Visit（换世界/重连）先收尾再开新的。 */
export function startSessionVisit(
  session: VoiceSession,
  worldId: string,
  playerId: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  now: number,
  device?: DeviceSnapshot | null,
): void {
  if (session.visit) void endSessionVisit(session, adapters, store, now); // 收尾旧的（同步排空 pending，抽取后台跑）
  session.visit = { id: store.startVisit(worldId, playerId, now, device), worldId, playerId, pending: new Map(), history: new Map(), summary: new Map(), compacting: new Set() };
}

/** 记一轮对话进当前 Visit 的增量；单角色超阈值即中途 flush 兜底（后台跑，不阻塞回复路径）。 */
export function recordVisitTurn(
  session: VoiceSession,
  worldId: string,
  playerId: string,
  characterId: string,
  transcript: string,
  replyText: string,
  adapters: ServiceAdapters,
  store: WorldStore,
): void {
  // 兜底：没经 world_info 起过 Visit（旧客户端/直连）时惰性开一段。
  if (!session.visit) {
    session.visit = { id: store.startVisit(worldId, playerId, Date.now()), worldId, playerId, pending: new Map(), history: new Map(), summary: new Map(), compacting: new Set() };
  }
  const visit = session.visit;
  // session 全量历史：供下一轮 routeIntent 整段回喂（不随中途 flush 清空，Visit 结束即弃）。
  const hist = visit.history.get(characterId) ?? [];
  hist.push({ role: 'child', text: transcript, ts: 0 }, { role: 'npc', text: replyText, ts: 0 });
  visit.history.set(characterId, hist);
  // 超阈值后台压缩（不阻塞回复路径；失败下轮再试）
  void maybeCompactVisit(session, characterId, adapters, store).catch(() => {});
  const turns = visit.pending.get(characterId) ?? [];
  turns.push({ child: transcript, npc: replyText });
  visit.pending.set(characterId, turns);
  if (turns.length >= VISIT_FLUSH_THRESHOLD) {
    const batch = turns.slice();
    turns.length = 0; // 清空已抽取的增量，后续轮次重新累积
    void flushMemory(visit.worldId, characterId, visit.playerId, batch, adapters, store).catch(() => {});
  }
}

/** 会话结束（leave_world / socket.close）：flush 当前 Visit（每个有增量的角色批量抽一次）并清出 session。 */
export async function endSessionVisit(
  session: VoiceSession,
  adapters: ServiceAdapters,
  store: WorldStore,
  endedAt: number,
): Promise<void> {
  const visit = session.visit;
  if (!visit) return;
  session.visit = null; // 先摘出，避免并发/重入重复 flush
  const jobs: Promise<void>[] = [];
  for (const [characterId, turns] of visit.pending) {
    if (turns.length === 0) continue;
    const batch = turns.slice();
    turns.length = 0;
    jobs.push(flushMemory(visit.worldId, characterId, visit.playerId, batch, adapters, store).catch(() => {}));
  }
  store.endVisit(visit.id, endedAt);
  await Promise.all(jobs);
}

/** 得奖语音表扬：委托人音色念表扬词（含盖章/升花反馈），合成好推 praise_tts（尽力而为，失败不影响主流程）。 */
async function pushPraiseTts(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  task: ActiveTask,
  settle: { flowerGained: boolean; wallet: Wallet },
  clientTts = false,
): Promise<void> {
  const npc = store.getCharacter(worldId, task.npcId);
  await pushLineTts(socket, adapters, store, praiseLine(task, settle), npc?.voiceId ?? 'cn-child-default', clientTts);
}

/**
 * 下发当前场景每个村民的漏话候选（心愿池随 discovered 变化，所以按玩家算、不能挂在 Character 上）。
 *
 * 下发的是【整个 leaks 数组】而不是一句：客户端自己轮换着播，省掉「播一句问一次」的往返。
 * 播不播、什么时候播、离多远播多响，全是客户端的事（漏话是环境音，见 npc_wish_voice.gd）。
 * 仙子不在列——她的台词是构建期预制 WAV（离线可用、零成本），走 FairyVoice 那条路。
 */
function pushWishes(
  socket: { send: (data: string) => void },
  store: WorldStore,
  worldId: string,
  playerId: string,
  sceneId: string,
): void {
  const discovered = store.getDiscovered(worldId, playerId);
  const canAfford = store.getWallet(worldId, playerId).flowers > 0; // 买不起就不勾（见 WishDef.costsFlower）
  const wishes = store
    .listCharacters(worldId, sceneId)
    .filter((c) => !c.isFairy)
    .map((c) => {
      const wish = wishFor(c.id, discovered, canAfford);
      return {
        characterId: c.id,
        voiceId: c.voiceId,
        // 心愿池空（玩法全发现/都买不起）→ 给纯氛围自语，让世界还有活气，但不再勾任何玩法
        lines: wish ? wish.leaks : IDLE_DOING,
      };
    });
  // discovered 一并下发：仙子的引路提示门禁（world.gd 的 _guide_used）本来只记「本次进世界」，
  // 重启就忘 → 明明用过引路了她还在念叨，正好砸了「已发现的不再提」这条承诺。
  // 持久口径在服务端，客户端据此初始化。
  socket.send(JSON.stringify({ type: 'npc_wishes', worldId, sceneId, wishes, discovered }));
}

/**
 * 一个玩法【真正成功】了（造出了东西 / 开了一局游戏 / 仙子答应带路）——心愿闭环的唯一入口。
 *
 * 两件事：
 * ① 记进 discovered：此后全世界再没人漏这个心愿的话（「已发现的不再提」，见 wishes.ts）。
 * ② 若进行中的委托正是盼着它的那个心愿 → 盖章 + 让【许愿的那个村民】用自己的音色道谢。
 *    这一步是满足感的闭环：小朋友帮了忙，得有人认出来并激动。少了它，漏话就只是句怪话。
 *
 * 复用 task_complete 报文 = 客户端零改动就有现成的盖章庆祝演出。
 */
async function fulfillAbility(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  playerId: string,
  ability: string,
  clientTts = false,
  sceneId = DEFAULT_SCENE,
  refine?: { itemRef: string; size: CreatureSize }, // A1：造物类带体型 → 开「试用」两段化；不带则一段完成
): Promise<void> {
  store.addDiscovered(worldId, playerId, ability);
  // 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md）：造物类心愿造成功后不当场盖章——
  // 先开「试用」：村民走过去用、发现「还差一点」，小朋友调对体型再盖章。只对 pending 的匹配 wish 生效。
  if (refine) {
    const trial = beginWishTrial(worldId, playerId, ability, refine.itemRef, refine.size, store);
    if (trial) {
      const npc = store.getCharacter(worldId, trial.task.npcId);
      const complaint = pickComplaint(trial.dir);
      // 客户端据此高亮那件东西 + 出「变大/变小」箭头 + 播仙子问句（预制 WAV），村民抱怨走下面 TTS 通道。
      socket.send(JSON.stringify({
        type: 'wish_trial', worldId, sceneId,
        npcId: trial.task.npcId, itemRef: refine.itemRef,
        refineDir: trial.dir, fromSize: refine.size,
        complaint, voiceId: npc?.voiceId ?? '', fairyHint: REFINE_HINT,
      }));
      // 村民用自己音色漏那句「还差一点」（与道谢同一条 TTS 通道）。
      await pushLineTts(socket, adapters, store, complaint, npc?.voiceId ?? 'cn-child-default', clientTts);
      // 玩法已被发现（addDiscovered 上面已写）→ 漏话池刷新（与一段完成一致，避免已发现的还在漏）。
      pushWishes(socket, store, worldId, playerId, sceneId);
      return; // 试用中：不盖章，等 wish_refine 调对/达上限才结算
    }
  }
  const done = completeWishOnAbility(worldId, playerId, ability, store);
  if (done) {
    socket.send(JSON.stringify({
      type: 'task_complete',
      task: done.task,
      stampStyle: done.task.stampStyle,
      flowerGained: done.flowerGained,
      wallet: done.wallet,
    }));
    await pushPraiseTts(socket, adapters, store, worldId, done.task, done, clientTts);
  }
  // 无条件重发漏话：心愿池此刻至少有两种变法——① 刚发现的玩法出池（「已发现的不再提」），
  // ② 造物刚花掉最后一朵花，costsFlower 的心愿集体买不起了（见 WishDef.costsFlower）。
  // ②不伴随 discovered 变化，所以不能只在「首次发现」时重发。
  pushWishes(socket, store, worldId, playerId, sceneId);
}

/** 造物/造角色余额检查：至少 1 朵小红花才放行。 */
function hasFlower(store: WorldStore, worldId: string, playerId: string): boolean {
  return store.getWallet(worldId, playerId).flowers >= 1;
}

/**
 * 小红花用完拦截：下发拒绝消息（带引导语文本 + 仙子语音 + 最新钱包），客户端据此让仙子引导去攒花。
 * kind=prop → prop_denied；kind=character → gen_denied（与生图失败的 gen_failed 区分开）。
 */
async function denyForNoFlowers(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  worldId: string,
  playerId: string,
  kind: 'prop' | 'character' | 'sticker',
  clientTts = false,
): Promise<void> {
  const line = flowerDeniedLine();
  const fairy = store.listCharacters(worldId).find((c) => c.isFairy);
  let ttsAsset = '';
  if (fairy && !clientTts) {
    try {
      ttsAsset = store.putAsset(await adapters.tts.synthesize(line, fairy.voiceId));
    } catch (err) {
      console.warn(`小红花引导语 TTS 合成失败（不阻塞）：${String(err)}`);
    }
  }
  socket.send(JSON.stringify({
    // sticker 复用造物的 prop_denied UX（都进背包、都要攒花），character 走 gen_denied。
    type: kind === 'character' ? 'gen_denied' : 'prop_denied',
    reason: 'no_flowers',
    message: line,
    ttsAsset,
    voiceId: fairy?.voiceId ?? '',
    wallet: store.getWallet(worldId, playerId),
  }));
}

/** 引导式创造会话入口（造角色/造物共用）：先卡余额（0 花不进会话，仙子引导），够花再开会话推进第一轮。 */
async function openCreationSession(
  socket: { send: (data: string) => void },
  session: VoiceSession,
  worldId: string,
  fairyId: string,
  request: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  leadIn = '', // 入口那轮 routeIntent 生成的仙子应答句（缺陷 ②：此前被丢弃）
  goal: CreationGoal = 'character',
  spawn?: SpawnCtx, // 造角色的降生上下文（落在发起者身边 + 广播给同场景的人）
  blueprintId?: string, // goal==='build' 时：拼哪副蓝图（matchBlueprint 命中的整体）
): Promise<void> {
  if (!hasFlower(store, worldId, session.playerId)) {
    // 拼装（build）与造物（prop）共用 prop_denied 拒绝 UX（都进背包、都要攒花）。
    const denyKind = goal === 'character' ? 'character' : goal === 'sticker' ? 'sticker' : 'prop';
    await denyForNoFlowers(socket, adapters, store, worldId, session.playerId, denyKind, session.clientTts);
    return;
  }
  session.creation = newCreationState(goal, blueprintId);
  // 仙子最近帮这个小朋友造过的东西：注入 guide，「帮我造刚才的小动物」这类指代能对上
  const creations = store.getMemories(fairyId, session.playerId).filter((m) => m.kind === 'creation');
  if (creations.length > 0) session.creation.recentCreations = creations.slice(-5).map((m) => m.text);
  // 积木拼装走 advanceBuild（按功能追问填槽）；造角色/物/贴纸走 advanceCreation（追问属性）。
  if (goal === 'build') {
    await advanceBuild(socket, session, worldId, fairyId, request, adapters, store, leadIn);
  } else {
    await advanceCreation(socket, session, worldId, fairyId, request, adapters, store, leadIn, spawn);
  }
}

/**
 * play_game 异步落地（realtime-primitives P5）：口语游戏 → 小仙子先出声应下 → LLM 生成【真 TS】剧本
 * → 过 typecheck（失败带错回喂重生成）→ buildStageOptsFromDraft 映射真实村民 → StageDirector.startStage 开演。
 * 与造物/造角色不同：游戏【不扣小红花】（自由玩）。
 * 兜底顺序讲究：先判「能不能开」（世界在否/已在演出/并发满）再出声应下——避免先说「好呀我们来玩」又紧跟
 * 「其实正在玩呢」自相矛盾；确定能开才应下（应答句先行，别在强模型 codegen 的几秒里干等）。
 * 生成失败 / 人不够 / 生成期间被别人抢先 → 一句温柔口头兜底，不开演、不炸。
 */
export async function startGameAsync(
  socket: { send: (data: string) => void },
  session: VoiceSession,
  worldId: string,
  fairyId: string,
  gameDesc: string,
  leadIn: string, // routeIntent 生成的仙子应答句（如「好呀，我们来玩！」）
  adapters: ServiceAdapters,
  store: WorldStore,
  hub?: WorldHub,
  stages?: StageDirector,
): Promise<void> {
  const fairy = store.getCharacter(worldId, fairyId);
  const voiceId = fairy?.voiceId ?? '';
  const say = (text: string) => pushLineTts(socket, adapters, store, text, voiceId, session.clientTts);
  const BUSY_LINE = '我们正在玩一个游戏呢，玩完这个再玩别的好不好？';
  if (!hub || !stages) return; // 编程错误（3 条 voice 路径都传了 hub/stages）；prod 不会到这
  if (!store.getWorld(worldId)) { await say('咦，这个世界好像不见啦，我们待会儿再玩好不好？'); return; }

  // 先判「能不能开」再应下——别先说「好呀我们来玩」又紧跟「其实正在玩呢」自相矛盾。
  // 已在演出 / 全局并发上限：只说兜底句，不发那句应答。
  if (stages.activeIn(worldId)) { await say(BUSY_LINE); return; }
  if (stages.atCapacity()) { await say('现在好多小朋友都在玩游戏，稍等一会儿再来玩好不好？'); return; }

  // 能开了才应下：孩子立刻听到「好呀，我们来玩！」，别在强模型 codegen 的几秒里干等。
  await say(leadIn || '好呀，我们来玩！');

  const sceneId = session.currentScene;
  const villagerNames = store.listCharacters(worldId, sceneId).filter((c) => !c.isFairy).map((c) => c.name);
  const hasPlayer = !!session.playerId && hub.membersIn(worldId).some((m) => m.playerId === session.playerId);

  let draft;
  try {
    draft = await adapters.llm.generateScreenplay({ gameDesc, villagerNames, hasPlayer });
  } catch (err) {
    console.warn(`[play_game] 生成剧本异常：${String(err)}`);
    await say('这个游戏我还没学会呢，我们先玩点别的好不好？');
    return;
  }
  if (!draft) { await say('这个游戏有点难，我还没学会呢，我们先玩点别的好不好？'); return; }

  const built = buildStageOptsFromDraft(draft, store, hub, worldId, session.playerId, sceneId);
  if (!built.ok) { await say(`${built.reason}，我们下次再玩这个好不好？`); return; }

  // 生成期间（几秒）可能有别人先开了一场（activeIn 之后、startStage 之前的窗口）：startStage 返回 null，
  // 此时才「先应下又落空」，但这是真「刚好被别人抢先」，说 BUSY_LINE 合理。
  const run = stages.startStage(worldId, built.opts);
  if (!run) { await say(BUSY_LINE); return; }
  // 不 await 终局：演出要演几分钟，stage_begin 已广播给全场，这里只管把它跑起来。
  void run.catch(() => {});
  // 真开演了才算「发现了能一起玩游戏」——前面每个 return 都是没开成，不能算。
  await fulfillAbility(socket, adapters, store, worldId, session.playerId, 'play_game', session.clientTts, session.currentScene);
}

async function pushLineTts(
  socket: { send: (data: string) => void },
  adapters: ServiceAdapters,
  store: WorldStore,
  text: string,
  voiceId: string,
  clientTts = false,
): Promise<void> {
  // clientTts：不合成，发文本+voiceId 让客户端自己念（payload 带 text 是新字段，老客户端只认 ttsAsset 不受影响）。
  if (clientTts) {
    socket.send(JSON.stringify({ type: 'praise_tts', ttsAsset: '', text, voiceId }));
    return;
  }
  try {
    const audio = await adapters.tts.synthesize(text, voiceId);
    socket.send(JSON.stringify({ type: 'praise_tts', ttsAsset: store.putAsset(audio), text, voiceId }));
  } catch (err) {
    console.warn(`表扬/致谢 TTS 合成失败（不影响主流程）：${String(err)}`);
  }
}

/** create_prop 异步落地：扣 1 花 → 审核 → LLM 设计 spec → 校验 → items 实体行 + 背包一份
 *  → item_created 推送（含实体行/钱包/背包）。客户端凭它在玩家旁找位发 item_place，
 *  渲染统一等 terrain_patch 广播（万物皆物品）。
 *  0 花拦截推 prop_denied；任何失败（审核/校验/异常）都退还那朵花并推 prop_failed。 */
export async function createPropAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  playerId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  clientTts = false,
  creatorId = '', // 造物的角色（小仙子）：给了就在造完后记一条 creation 记忆（「帮我造刚才的」指代用）
  sceneId = DEFAULT_SCENE, // 造完要按玩家所在场景重发漏话（心愿池随 discovered/钱包变）
): Promise<void> {
  if (!store.spendFlower(worldId, playerId)) {
    await denyForNoFlowers(socket, adapters, store, worldId, playerId, 'prop', clientTts);
    return;
  }
  // 开造即报：客户端据此退出对话、就地立起魔法熔炉，孩子自由走动而不是卡在对话里干等。
  // 必须抢在设计/校验之前发——那两步慢，等它们跑完再报，占位符就没意义了。
  socket.send(JSON.stringify({ type: 'prop_pending', worldId, wallet: store.getWallet(worldId, playerId) }));
  let created = false;
  try {
    const check = await adapters.moderation.moderateText(description);
    if (!check.allowed) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: 'moderation blocked' }));
      return;
    }
    const spec = await adapters.llm.designSdfProp(description);
    const validated = validateSdfPropSpec(spec);
    if (!validated.ok) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: validated.error }));
      return;
    }
    const def = creationItemDef(worldId, randomUUID(), validated.spec);
    store.upsertItem(def);
    store.bagAdd(worldId, playerId, def.id);
    created = true;
    // 造物记忆：仙子记下帮这个小朋友变过什么，下次「帮我变刚才那个」能对上
    if (creatorId) {
      store.addMemory(creatorId, { text: `帮小朋友变过「${def.name}」（${description.slice(0, 60)}）`, kind: 'creation', aboutPlayer: playerId, ts: 0 });
    }
    socket.send(JSON.stringify({
      type: 'item_created',
      worldId,
      item: def,
      wallet: store.getWallet(worldId, playerId),
      bag: store.getBag(worldId, playerId),
    }));
    // 造物成功 = 发现了「能造东西」这个玩法；若有村民正盼着它 → 开「试用」（A1：造出来带体型，
    // 村民试用差一点，小朋友调对再盖章）。体型取自造物 spec.scale 反推的档。
    await fulfillAbility(socket, adapters, store, worldId, playerId, 'create_prop', clientTts, sceneId,
      { itemRef: def.id, size: scaleToSize(validated.spec.scale) });
  } catch (err) {
    socket.send(JSON.stringify({ type: 'prop_failed', reason: String(err) }));
  } finally {
    if (!created) store.refundFlower(worldId, playerId); // 造失败/被审核挡：退还，别让孩子白花一朵
  }
}

/** create_sticker 异步落地（fairy-stickers）：与 createPropAsync 平行，但产物是扁平 die-cut 贴纸。
 *  扣花 → sticker_pending → 审核描述 → designSticker(名字+英文生图 prompt) → generateIconAsset 管线
 *  （生图→抠图→加白边→存资产哈希）→ creationStickerDef(mount:'edge', renderRef `sticker:@<hash>`) →
 *  upsertItem + bagAdd → item_created 推送（复用造物落地路径：进背包，摆放走放置模式）。
 *  0 花拦截推 prop_denied（复用造物拒绝 UX）；任何失败都退还那朵花并推 prop_failed。 */
export async function createStickerAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  playerId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  clientTts = false,
  creatorId = '', // 造贴纸的角色（小仙子）：给了就在造完后记一条 creation 记忆
  sceneId = DEFAULT_SCENE, // 造完要按玩家所在场景重发漏话
): Promise<void> {
  if (!store.spendFlower(worldId, playerId)) {
    await denyForNoFlowers(socket, adapters, store, worldId, playerId, 'sticker', clientTts);
    return;
  }
  // 开造即报：客户端据此退出对话、就地立起占位符（复用造物的 prop_pending 熔炉动静）。
  socket.send(JSON.stringify({ type: 'sticker_pending', worldId, wallet: store.getWallet(worldId, playerId) }));
  let created = false;
  try {
    const check = await adapters.moderation.moderateText(description);
    if (!check.allowed) {
      socket.send(JSON.stringify({ type: 'sticker_failed', reason: 'moderation blocked' }));
      return;
    }
    const { name, prompt } = await adapters.llm.designSticker(description);
    // 复用图标专用管线：扁平生图 → 绿幕抠图 → 程序加白 die-cut 贴纸边 → 存资产哈希。
    const assetHash = await generateIconAsset(adapters, prompt, store);
    const def = creationStickerDef(worldId, randomUUID(), name, assetHash);
    store.upsertItem(def);
    store.bagAdd(worldId, playerId, def.id);
    created = true;
    if (creatorId) {
      store.addMemory(creatorId, { text: `帮小朋友做过「${def.name}」贴纸（${description.slice(0, 60)}）`, kind: 'creation', aboutPlayer: playerId, ts: 0 });
    }
    socket.send(JSON.stringify({
      type: 'item_created',
      worldId,
      item: def,
      wallet: store.getWallet(worldId, playerId),
      bag: store.getBag(worldId, playerId),
    }));
    await fulfillAbility(socket, adapters, store, worldId, playerId, 'create_sticker', clientTts, sceneId);
  } catch (err) {
    socket.send(JSON.stringify({ type: 'sticker_failed', reason: String(err) }));
  } finally {
    if (!created) store.refundFlower(worldId, playerId); // 造失败/被审核挡：退还
  }
}

/** 积木式造物落成（B1，docs/kids-thinking-build-from-parts.md §3.1/§4.3）：与 createStickerAsync 平行，
 *  但产物是组合物零件树（renderRef='composed:'）而非生成图——零件全来自预置库，无需生图/审核。
 *  扣花 → prop_pending（复用造物占位 UX）→ 按 blueprintId + 已填槽拼出 ComposedSpec → creationBuildDef
 *  → upsertItem + bagAdd → item_created（进背包，摆放走放置模式）。0 花拦截推 prop_denied，任何失败退还那朵花。
 *  落成扣费时机与「确认要造的那一刻」一致（拼装期零件免费，预置库无限量）。 */
export async function createBuildAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  playerId: string,
  blueprintId: string,
  filled: Record<string, string>, // slotId → partId（会话累积的已填槽）
  adapters: ServiceAdapters,
  store: WorldStore,
  clientTts = false,
  creatorId = '', // 拼装引导的角色（小仙子）：给了就在落成后记一条 creation 记忆
  sceneId = DEFAULT_SCENE, // 造完要按玩家所在场景重发漏话
): Promise<void> {
  if (!store.spendFlower(worldId, playerId)) {
    await denyForNoFlowers(socket, adapters, store, worldId, playerId, 'prop', clientTts);
    return;
  }
  // 开造即报：复用造物 prop_pending，客户端据此退对话、就地立占位符。
  socket.send(JSON.stringify({ type: 'prop_pending', worldId, wallet: store.getWallet(worldId, playerId) }));
  let created = false;
  try {
    const bp = findBlueprint(blueprintId);
    if (!bp) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: 'unknown blueprint' }));
      return;
    }
    // 按蓝图槽序收拢已填零件（跳过没填的选填槽/丢失的零件），冗余 partRenderRef 供客户端直接画子 quad。
    const parts: ComposedPart[] = [];
    for (const slot of bp.slots) {
      const partId = filled[slot.slotId];
      if (!partId) continue;
      const part = findPart(partId);
      if (!part) continue;
      // fit 校验（权威，两条路径共用）：零件必须能挂进该槽（fitSlots 含槽 accept），否则丢弃。
      // 引导会话路径的零件本就来自 partsForSlot 兼容表、天然通过；这里主要防复用改装（create_build）
      // 传来对不上的槽零件——服务端绝不落一个歪拼的组合物。
      if (!part.fitSlots.includes(slot.accept)) continue;
      parts.push({ slotId: slot.slotId, partId, partRenderRef: part.renderRef });
    }
    if (parts.length === 0) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: 'empty build' }));
      return;
    }
    const spec: ComposedSpec = { blueprintId, parts };
    const def = creationBuildDef(worldId, randomUUID(), bp.name, spec);
    store.upsertItem(def);
    store.bagAdd(worldId, playerId, def.id);
    created = true;
    if (creatorId) {
      store.addMemory(creatorId, { text: `帮小朋友拼出「${def.name}」（${parts.length}个零件）`, kind: 'creation', aboutPlayer: playerId, ts: 0 });
    }
    socket.send(JSON.stringify({
      type: 'item_created',
      worldId,
      item: def,
      wallet: store.getWallet(worldId, playerId),
      bag: store.getBag(worldId, playerId),
    }));
    await fulfillAbility(socket, adapters, store, worldId, playerId, 'create_prop', clientTts, sceneId);
  } catch (err) {
    socket.send(JSON.stringify({ type: 'prop_failed', reason: String(err) }));
  } finally {
    if (!created) store.refundFlower(worldId, playerId); // 落成失败：退还，别让孩子白花一朵
  }
}

/** 复用改装（B1，docs/kids-thinking-build-from-parts.md §3.1）：某副蓝图每个槽的兼容零件表
 *  （slotId → [{id,label,renderRef}]）。客户端进改装时一次性取回，之后本地即时建零件盘换槽——
 *  零件库保持服务端权威，客户端不必再造一份镜像。未知蓝图返回空表。 */
export function buildSlotOptions(blueprintId: string): Record<string, Array<{ id: string; label: string; renderRef: string }>> {
  const bp = findBlueprint(blueprintId);
  if (!bp) return {};
  const out: Record<string, Array<{ id: string; label: string; renderRef: string }>> = {};
  for (const slot of bp.slots) {
    out[slot.slotId] = partsForSlot(slot.accept).map((p) => ({ id: p.id, label: p.name, renderRef: p.renderRef }));
  }
  return out;
}

/** create_character 异步落地：造角色管线（spec→审核→生图→抠图→持久化），gen_progress 逐阶段推、
 *  完成 gen_complete、失败 gen_failed。与 create_character_request 复用同一实现；语音触发时不自带 gate
 *  （语音回合已在上层限流，与 createPropAsync 一致）。 */
export async function createCharacterAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  playerId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  toSpriteSheet?: ToSpriteSheet,
  clientTts = false,
  creatorId = '', // 造角色的角色（小仙子）：给了就在造完后记一条 creation 记忆（「帮我造刚才的」指代用）
  spawn?: SpawnCtx, // 降生上下文：落在发起者所在场景/身边 + 向同场景其他人广播 character_spawned
): Promise<void> {
  if (!store.spendFlower(worldId, playerId)) {
    await denyForNoFlowers(socket, adapters, store, worldId, playerId, 'character', clientTts);
    return;
  }
  const requestId = randomUUID();
  let created = false;
  try {
    // 降生位置/场景：跟发起者走。不给的话 createCharacter 会一律落到 DEFAULT_SCENE 的世界中心，
    // 于是「在森林里造的角色出现在村子中央」——别人重进场景时才会发现它跑错地方了。
    const sceneId = spawn?.sceneId;
    const position = sceneId ? store.getPlayerTile(worldId, sceneId, playerId) : undefined;
    const character = await createCharacter(
      { worldId, intentText: description, byFairy: true, sceneId, position },
      adapters,
      store,
      (stage) => socket.send(JSON.stringify({ type: 'gen_progress', requestId, stage })),
    );
    created = true;
    // 造物记忆：仙子记下帮这个小朋友造过谁，下次「帮我造刚才的小动物，但是会飞的」能对上
    if (creatorId) {
      store.addMemory(creatorId, { text: `帮小朋友造过新伙伴「${character.name}」（${description.slice(0, 60)}）`, kind: 'creation', aboutPlayer: playerId, ts: 0 });
    }
    socket.send(JSON.stringify({ type: 'gen_complete', requestId, character, wallet: store.getWallet(worldId, playerId) }));
    // 同场景其他人：实时看见新伙伴降生（排除发起者——它已经靠 gen_complete 降生过了）。
    if (spawn?.hub && sceneId) {
      spawn.hub.broadcastScene(
        worldId, sceneId,
        { type: 'character_spawned', sceneId, character },
        spawn.connKey,
      );
    }
    // 静态立绘先给客户端，idle 动画后台异步补（客户端凭 spriteAsset 轮询 /sprite-anim/:hash）
    if (character.appearance.spriteAsset) {
      triggerCharacterAnimation(adapters, store, character.appearance.spriteAsset, toSpriteSheet);
    }
    // A1 试用：造出来的新伙伴带体型 → 开「试用」（村民试用差一点，小朋友调对再盖章）。
    await fulfillAbility(socket, adapters, store, worldId, playerId, 'create_character', clientTts, sceneId ?? DEFAULT_SCENE,
      { itemRef: character.id, size: character.appearance.size ?? scaleToSize(character.appearance.scale) });
  } catch (err) {
    const reason = err instanceof ModerationError ? err.message : String(err);
    socket.send(JSON.stringify({ type: 'gen_failed', requestId, reason }));
  } finally {
    if (!created) store.refundFlower(worldId, playerId); // 造失败：退还，别让孩子白花一朵
  }
}

/**
 * 引导式创造图标批量生成：遍历图标库每个选项，走图标专用管线 generateIconAsset
 * （图标画风生图→抠图→程序加白 die-cut 边→putAsset）出一张图，存「option id→asset hash」映射。
 * 覆盖造角色全库 + 造物专属 kind/motion（prop_ 前缀）+ 造贴纸专属 kind 图案（stk_ 前缀）；
 * 造物/贴纸的 color/size 复用造角色同 id，不重复生成（同 id 幂等跳过）。
 * 幂等：已生成的跳过，除非 force。opts.only 限定只生成指定 id。
 * 返回生成/跳过/失败清单。绝不抛（单项失败不影响其它）。
 */
export async function generateCreationIcons(
  adapters: ServiceAdapters,
  store: WorldStore,
  opts: { force?: boolean; only?: string[] } = {},
): Promise<{ generated: string[]; skipped: string[]; failed: string[] }> {
  const generated: string[] = [];
  const skipped: string[] = [];
  const failed: string[] = [];
  const onlySet = opts.only && opts.only.length > 0 ? new Set(opts.only) : null;
  // 待生成图标 = 造角色全库(iconPrompt) + 造物专属 kind/motion(propIconPrompt)。
  // 造物的 color/size 是造角色的同 id，已在 CREATION_OPTIONS 里，不再单列（避免重复生成）。
  const jobs: { id: string; prompt: string }[] = [
    ...CREATION_OPTIONS.map((o) => ({ id: o.id, prompt: iconPrompt(o.id) })),
    ...PROP_CREATION_OPTIONS.filter((o) => o.id.startsWith('prop_')).map((o) => ({ id: o.id, prompt: propIconPrompt(o.id) })),
    // 造贴纸专属图案(stk_ 前缀)：color 复用造角色同 id、不重复生成，与造物同理。
    ...STICKER_CREATION_OPTIONS.filter((o) => o.id.startsWith('stk_')).map((o) => ({ id: o.id, prompt: stickerIconPrompt(o.id) })),
  ];
  for (const job of jobs) {
    if (onlySet && !onlySet.has(job.id)) continue;
    if (!opts.force && store.getCreationIcon(job.id)) {
      skipped.push(job.id);
      continue;
    }
    try {
      const hash = await generateIconAsset(adapters, job.prompt, store);
      store.setCreationIcon(job.id, hash);
      generated.push(job.id);
    } catch (err) {
      console.warn(`创造图标生成失败（${job.id}，跳过）：${String(err)}`);
      failed.push(job.id);
    }
  }
  return { generated, skipped, failed };
}

/**
 * 引导式造角色一轮（见 docs/guided-creation-design.md）：
 * guideCreation 判断 → 累积属性 → 要么 done→createCharacterAsync 收尾，要么发 creation_prompt 继续追问。
 * childInput = 幼儿这轮的输入（点的选项 label 或说的话）；fairyId 用来取仙子音色合成问句 TTS。
 * 出错兜底：直接用当前累积描述去造，绝不把幼儿卡在半开会话里。
 */
/**
 * leadIn：造角色入口那一轮，routeIntent 给小仙子生成的应答句（如「好呀，我这就变出来！」）。
 * 此前它被 respondToTranscript 早返回丢弃，小朋友说完「我想要一只小猫」仙子不接话、直接开始
 * 追问细节（缺陷 ②）。这里把它接回来：
 *   - 追问路径：并进第一个问句一起念（一次 TTS，避免两条消息各自起播互相抢断）
 *   - 快捷路径（首轮即 done）：单独念出来，别吞掉
 * 只有入口那一次传 leadIn；后续每轮 creation_reply 都不带。
 */
/** 引导式创造的追问轮数上限：到线仍未 done 就用现有属性强制造（与 mock 的 turnCount>=5 同值）。 */
const CREATION_MAX_TURNS = 5;

export async function advanceCreation(
  socket: { send: (data: string) => void },
  session: VoiceSession,
  worldId: string,
  fairyId: string,
  childInput: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  leadIn = '',
  spawn?: SpawnCtx, // 造角色的降生上下文（落在发起者身边 + 广播给同场景的人）
): Promise<void> {
  const state = session.creation;
  if (!state) return;
  const isProp = state.goal === 'prop';
  const isSticker = state.goal === 'sticker';
  // 会话目标决定汇总描述用哪套：造贴纸 composeStickerDesc，造物 composePropDesc，造角色 describeCreationAttrs。
  const summarize = () => isSticker ? composeStickerDesc(state.attrs) : isProp ? composePropDesc(state.attrs) : describeCreationAttrs(state);
  // done 时按目标分派到对应的异步造：造贴纸 createStickerAsync，造物 createPropAsync，造角色 createCharacterAsync。
  // 造贴纸/造物都进背包（私有，不广播；摆放走放置模式 terrain_patch 自带实体定义），只有造角色要降生广播。
  const finishCreate = (desc: string) => isSticker
    ? createStickerAsync(socket, worldId, session.playerId, desc, adapters, store, session.clientTts, fairyId, session.currentScene)
    : isProp
      ? createPropAsync(socket, worldId, session.playerId, desc, adapters, store, session.clientTts, fairyId, session.currentScene)
      : createCharacterAsync(socket, worldId, session.playerId, desc, adapters, store, undefined, session.clientTts, fairyId, spawn);
  const fairyVoice = store.getCharacter(worldId, fairyId)?.voiceId ?? FAIRY_VOICE;
  // 超轮兜底（适配器无关）：已追问满上限还没 done，就用现有属性直接造——绝不无限追问。
  // 此前只有 mock 在 turnCount>=5 时强制 done，线上 LLM 属性解析不进去就会原地循环。
  if (state.turnCount >= CREATION_MAX_TURNS) {
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finishCreate(summarize() || childInput);
    return;
  }
  let r;
  try {
    r = isSticker ? await adapters.llm.guideSticker(state, childInput) : isProp ? await adapters.llm.guideProp(state, childInput) : await adapters.llm.guideCreation(state, childInput);
  } catch (err) {
    // guide 挂了：用现有属性兜底造，不让幼儿卡住
    console.warn(`guide(${state.goal}) 失败，用现有属性兜底造：${String(err)}`);
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finishCreate(summarize() || childInput);
    return;
  }
  // 小朋友反悔（guide 判的语义取消：「算了」「不要了」）：清会话 + 通知客户端收视图/收占位符，绝不开造、不扣花。
  // 入口那轮的前置话语不再念——孩子已经改主意了，接着念「好呀我这就变出来」只会更乱。
  if (r.cancelled) {
    session.creation = null;
    let ttsAsset = '';
    if (!session.clientTts) {
      try {
        ttsAsset = store.putAsset(await adapters.tts.synthesize(r.replyText, fairyVoice));
      } catch (err) {
        console.warn(`取消安抚语 TTS 失败（不阻塞，客户端仍会收视图）：${String(err)}`);
      }
    }
    socket.send(JSON.stringify({
      type: 'creation_cancelled',
      goal: state.goal,
      replyText: r.replyText,
      ttsAsset,
      voiceId: fairyVoice,
    }));
    return;
  }
  // 累积这轮解析出的增量
  const u = r.updatedAttrs;
  if (u) {
    if (u.kind) state.attrs.kind = u.kind;
    if (u.color) state.attrs.color = u.color;
    if (u.size) state.attrs.size = u.size;
    if (u.personality) state.attrs.personality = u.personality;
    if (u.name) state.attrs.name = u.name;
    if (u.motion) state.attrs.motion = u.motion;
    if (u.traits) state.attrs.traits = u.traits;
  }
  if (r.category) state.askedCategories.push(r.category);
  // 会话对话入账：这轮小朋友说的 + 仙子接下来的追问，下一轮按多轮 messages 回放给 guide。
  state.dialog.push({ role: 'child', text: childInput, ts: 0 });
  if (!r.done) state.dialog.push({ role: 'npc', text: r.question ?? r.replyText, ts: 0 });
  state.turnCount += 1;
  if (r.done) {
    session.creation = null;
    // 快捷路径：一句说全、首轮即造。没有问句可以搭载，前置话语单独念出来，别吞掉。
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finishCreate(r.description || summarize() || childInput);
    return;
  }
  // 追问：合成仙子问句 TTS（失败不阻塞；clientTts 时客户端自己合成）+ 下发图标选项卡
  const lookup = isSticker ? findStickerOption : isProp ? findPropOption : findOption;
  const options = (r.optionIds ?? [])
    .map((id) => lookup(id))
    .filter((o): o is NonNullable<typeof o> => !!o)
    .map((o) => ({ id: o.id, label: o.label, iconAsset: store.getCreationIcon(o.id) }));
  // 入口那轮把前置话语接在问句前面，一次念完（「好呀，我这就变出来！你想要什么样的小伙伴呀？」）。
  // 不另发一条 character_response：两条消息各自起播会互相抢断，前一句听不全。
  const spoken = leadIn ? `${leadIn}${r.replyText}` : r.replyText;
  let ttsAsset = '';
  if (!session.clientTts) {
    try {
      ttsAsset = store.putAsset(await adapters.tts.synthesize(spoken, fairyVoice));
    } catch (err) {
      console.warn(`造角色追问 TTS 失败（不阻塞，客户端可显示文字）：${String(err)}`);
    }
  }
  socket.send(JSON.stringify({
    type: 'creation_prompt',
    goal: state.goal, // 客户端据此在仙子身旁立降生蛋（character）还是魔法熔炉（prop）
    replyText: spoken,
    question: r.question ?? r.replyText, // 纯问句：客户端拿它做选项卡标题，不带前置话语
    category: r.category,
    options,
    ttsAsset,
    voiceId: fairyVoice,
  }));
}

/**
 * 引导式积木拼装推进（B1，docs/kids-thinking-build-from-parts.md §3.4）：与 advanceCreation 平行，
 * 但走 guideBuild（按未填必填槽的功能提问）→ 累积「哪个槽填了哪个零件」→ done→createBuildAsync 落成。
 * 结果类型（GuideBuildResult：filled/slotId）与 GuideCreationResult（updatedAttrs/category）不同，故独立成函数。
 * 兜底同 advanceCreation：guide 挂了/超轮就用已填零件直接落成，绝不把孩子卡在半开会话里。
 * childInput = 孩子这轮输入（点的零件 name 或语音功能词）；leadIn 只入口那轮传（升级造物→拼装那句应答）。
 */
export async function advanceBuild(
  socket: { send: (data: string) => void },
  session: VoiceSession,
  worldId: string,
  fairyId: string,
  childInput: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  leadIn = '',
): Promise<void> {
  const state = session.creation;
  if (!state || !state.build) return;
  const build = state.build;
  const fairyVoice = store.getCharacter(worldId, fairyId)?.voiceId ?? FAIRY_VOICE;
  const finish = () => createBuildAsync(
    socket, worldId, session.playerId, build.blueprintId, build.filled,
    adapters, store, session.clientTts, fairyId, session.currentScene,
  );
  const bp = findBlueprint(build.blueprintId);
  // 蓝图丢失（不该发生）：用已填零件兜底落成
  if (!bp) {
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finish();
    return;
  }
  // 超轮兜底：追问满上限还没 done，就用现有零件直接落成——绝不无限追问。
  if (state.turnCount >= CREATION_MAX_TURNS) {
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finish();
    return;
  }
  let r;
  try {
    r = await adapters.llm.guideBuild(state, childInput);
  } catch (err) {
    console.warn(`guideBuild 失败，用现有零件兜底落成：${String(err)}`);
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finish();
    return;
  }
  // 小朋友反悔（「算了/不拼了」）：清会话 + 通知客户端收占位符，绝不落成、不扣花。
  if (r.cancelled) {
    session.creation = null;
    let ttsAsset = '';
    if (!session.clientTts) {
      try {
        ttsAsset = store.putAsset(await adapters.tts.synthesize(r.replyText, fairyVoice));
      } catch (err) {
        console.warn(`取消安抚语 TTS 失败（不阻塞，客户端仍会收视图）：${String(err)}`);
      }
    }
    socket.send(JSON.stringify({
      type: 'creation_cancelled',
      goal: 'build',
      replyText: r.replyText,
      ttsAsset,
      voiceId: fairyVoice,
    }));
    return;
  }
  // 累积本轮增量：填槽（点选路径可能已在 WS 层直填，这里对已填是幂等覆写）+ 记问过的槽。
  if (r.filled) build.filled[r.filled.slotId] = r.filled.partId;
  if (r.slotId) build.askedSlots.push(r.slotId);
  state.dialog.push({ role: 'child', text: childInput, ts: 0 });
  if (!r.done) state.dialog.push({ role: 'npc', text: r.question ?? r.replyText, ts: 0 });
  state.turnCount += 1;
  if (r.done) {
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await finish();
    return;
  }
  // 追问：合成点点功能问句 TTS（失败不阻塞）+ 下发 build_prompt（当前槽 + 兼容零件盘，客户端点亮该槽发光）。
  const options = (r.optionIds ?? [])
    .map((id) => findPart(id))
    .filter((p): p is NonNullable<typeof p> => !!p)
    .map((p) => ({ id: p.id, label: p.name, renderRef: p.renderRef }));
  const spoken = leadIn ? `${leadIn}${r.replyText}` : r.replyText;
  let ttsAsset = '';
  if (!session.clientTts) {
    try {
      ttsAsset = store.putAsset(await adapters.tts.synthesize(spoken, fairyVoice));
    } catch (err) {
      console.warn(`拼装追问 TTS 失败（不阻塞，客户端可显示文字）：${String(err)}`);
    }
  }
  socket.send(JSON.stringify({
    type: 'build_prompt',
    blueprintId: build.blueprintId,
    replyText: spoken,
    question: r.question ?? r.replyText, // 纯功能问句：客户端拿它做选项卡标题，不带前置话语
    slotId: r.slotId,                    // 当前要填的槽：客户端点亮它发光
    options,
    ttsAsset,
    voiceId: fairyVoice,
  }));
}

/** 把累积属性汇成一句中文描述（兜底造角色用；与 mock 的 composeCreationDesc 同形）。 */
function describeCreationAttrs(state: CreationState): string {
  const a = state.attrs;
  if (!a.kind && !a.color && a.traits.length === 0) return '';
  const head = `一只${a.color ?? ''}${a.size ?? ''}的${a.kind ?? '小动物'}`;
  const parts = [head];
  if (a.traits.length > 0) parts.push(a.traits.join('、'));
  if (a.personality) parts.push(`性格${a.personality}`);
  if (a.name) parts.push(`叫${a.name}`);
  return parts.join('，');
}

/**
 * 在场玩家的对外视图：presence 快照 / actor_join 共用。
 * 位置流只在人动起来时才发，静止的玩家在别人屏幕上根本不存在——presence 让进场即可见，
 * 并把 spriteAsset 带过去，对端才能渲染真实立绘而不是一个泛蓝的占位小人。
 */
/**
 * 造角色的降生上下文：新角色落在发起者所在场景/身边，并向同场景其他人广播 character_spawned。
 * hub 缺省（单测/直连）时只影响广播，落位仍按 sceneId 走。
 */
export interface SpawnCtx {
  sceneId: string;
  hub?: WorldHub;
  /** 发起者连接：广播时排除它（它已经靠 gen_complete 降生过了，再收一次会重复）。 */
  connKey?: string;
}

/** 玩家 emote 动作白名单：表情盘八格 = 基础四动作 + heart（送爱心）+ 纸片动作精选三格。
 * 与客户端 EMOTE_PANEL_ACTIONS 同步；旧客户端收到不认识的动作会静默忽略（EMOTION_ICONS 门）。 */
const EMOTE_ACTIONS = new Set(['wave', 'jump', 'spin', 'nod', 'heart', 'flip', 'squish', 'paper_plane']);

export interface ActorPresence {
  playerId: string;
  name: string;
  spriteAsset: string;
  /** 玩家音色（playerId 稳定哈希，见 voiceForPlayer）：对端播放其 player_speech/招呼语用。 */
  voiceId: string;
  tile?: TilePos;
  /** 贴纸锚点（design §5 actors 流转发）：让「别人看到的我」也吃真锚点，老档缺省走对端 alpha 兜底。 */
  anchors?: CharacterAnchors;
}

/** 夹紧不可信的上报 anchors（world_info.profile 是设备端自报）：三点齐全且 x,y 有限才收、坐标夹到 [0,1]；否则 undefined。 */
export function sanitizeAnchors(v: unknown): CharacterAnchors | undefined {
  if (!v || typeof v !== 'object') return undefined;
  const o = v as Record<string, unknown>;
  const pt = (raw: unknown): AnchorPoint | undefined => {
    if (!raw || typeof raw !== 'object') return undefined;
    const r = raw as Record<string, unknown>;
    const x = Number(r.x);
    const y = Number(r.y);
    if (!Number.isFinite(x) || !Number.isFinite(y)) return undefined;
    return { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
  };
  const headTop = pt(o.headTop);
  const handL = pt(o.handL);
  const handR = pt(o.handR);
  if (!headTop || !handL || !handR) return undefined;
  return { headTop, handL, handR, source: o.source === 'vision' ? 'vision' : 'fallback' };
}

export function presenceOf(store: WorldStore, worldId: string, sceneId: string, playerId: string): ActorPresence {
  const p = store.getPlayer(playerId);
  return {
    playerId,
    name: p?.name ?? '',
    spriteAsset: p?.spriteAsset ?? '',
    voiceId: voiceForPlayer(playerId, p?.gender),
    tile: store.getPlayerTile(worldId, sceneId, playerId),
    ...(p?.anchors ? { anchors: p.anchors } : {}),
  };
}

/** 同世界同场景的其他在场玩家（排除自己）。 */
function presenceSnapshot(
  hub: WorldHub, store: WorldStore, worldId: string, sceneId: string, exceptClientId: string,
): ActorPresence[] {
  return hub
    .membersInScene(worldId, sceneId, exceptClientId)
    .filter((m) => m.playerId)
    .map((m) => presenceOf(store, worldId, sceneId, m.playerId));
}

/**
 * 进场景（首次进世界 / 走 portal）：给自己发同场景名单，给同场景其他人广播 actor_join。
 * 无 playerId（旧客户端/直连）时只发快照，不向别人宣告一个没有身份的连接。
 */
function announceSceneEntry(
  hub: WorldHub, store: WorldStore, socket: { send: (data: string) => void },
  worldId: string, sceneId: string, connKey: string, playerId: string,
): void {
  socket.send(JSON.stringify({
    type: 'actors_snapshot',
    sceneId,
    actors: presenceSnapshot(hub, store, worldId, sceneId, connKey),
  }));
  if (!playerId) return;
  hub.broadcastScene(
    worldId, sceneId,
    { type: 'actor_join', sceneId, actor: presenceOf(store, worldId, sceneId, playerId) },
    connKey,
  );
}

/** 连接退场(leave_world/断连)时摘出 hub；换 host 通知新 host，世界清空则杀掉进行中的演出。 */
export function notifyHubLeave(hub: WorldHub, connKey: string, stages?: StageDirector, playerId?: string): void {
  const left = hub.leave(connKey);
  if (!left) return;
  left.newHost?.send({ type: 'world_host', isHost: true });
  if (stages && hub.membersIn(left.worldId).length === 0) {
    stages.onWorldEmpty(left.worldId);
  } else if (playerId) {
    // 世界还有人：通知【同场景】的人即时清掉离场者的远端副本（否则要等 3s 插值缓冲陈旧才消失）。
    // 隔壁场景的人本来就看不见它，没必要收。
    hub.broadcastScene(left.worldId, left.sceneId, { type: 'actor_leave', playerId, sceneId: left.sceneId }, connKey);
  }
}

/** 某 tile 当前挂的物品实体 id（场景无矩阵/越界/坏字节/无物品 → ''）。item_place/pickup 共用。 */
function tileItemIdAt(store: WorldStore, worldId: string, sceneId: string, x: number, y: number): string {
  const rec = store.getSceneTerrain(worldId, sceneId);
  if (!rec) return '';
  try {
    const t = decodeTerrain(rec.bytes);
    if (x < 0 || x >= t.gridW || y < 0 || y >= t.gridH) return '';
    const ref = t.itemRef[y * t.gridW + x]!;
    return ref > 0 ? t.palette[ref - 1]! : '';
  } catch {
    return '';
  }
}

/** 某 tile 某条边当前挂的贴纸实体 id（同上语义，side 越界也回 ''）。 */
function tileEdgeItemIdAt(store: WorldStore, worldId: string, sceneId: string, x: number, y: number, side: number): string {
  const rec = store.getSceneTerrain(worldId, sceneId);
  if (!rec || !Number.isInteger(side) || side < 0 || side > 3) return '';
  try {
    const t = decodeTerrain(rec.bytes);
    if (x < 0 || x >= t.gridW || y < 0 || y >= t.gridH) return '';
    const ref = t.edges[side]![y * t.gridW + x]!;
    return ref > 0 ? t.palette[ref - 1]! : '';
  } catch {
    return '';
  }
}

/** 反查：某实体 id 当前挂在场景哪个 tile（体型调整要按 tile 重发编辑触发重渲染）。找不到回 null。 */
function findItemTile(store: WorldStore, worldId: string, sceneId: string, itemId: string): { x: number; y: number; yawDeg: number } | null {
  const rec = store.getSceneTerrain(worldId, sceneId);
  if (!rec) return null;
  try {
    const t = decodeTerrain(rec.bytes);
    const ref = t.palette.indexOf(itemId) + 1;
    if (ref === 0) return null;
    for (let i = 0; i < t.itemRef.length; i++) {
      if (t.itemRef[i] === ref) {
        return { x: i % t.gridW, y: Math.floor(i / t.gridW), yawDeg: (t.itemArg[i]! * 360) / 256 };
      }
    }
  } catch {
    return null;
  }
  return null;
}

/**
 * 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §4.2）：把小朋友调的那一下体型【应用】到世界并广播重渲染。
 * 老板拍板方案=服务端改尺寸+广播（不是客户端自改）。两条路径，按 refineItemRef 指向什么分发：
 *  - 造物（SDF item）：改 def.spec.scale=sizeToScale(newSize) → re-upsert → 定位它所在 tile → 复用
 *    editSceneTerrain（version+1 + terrain_patch 广播 + forceInclude 该 def）让客户端覆写目录后按新 scale 重绘。
 *    还在背包没落地（找不到 tile）就只改 def——下次摆出来自然是新尺寸。
 *  - 角色：改 appearance.size/scale → 落库 → character_resized 定向广播 → 客户端重算 pixel_size。
 * 只改倍率、不重新生图、不动资产哈希（size 是纯标量轴，§3.1）。
 */
function applyRefineResize(
  store: WorldStore,
  hub: WorldHub | undefined,
  worldId: string,
  currentScene: string,
  itemRef: string,
  newSize: CreatureSize,
): void {
  const scale = sizeToScale(newSize);
  const def = store.getItemDef(worldId, itemRef);
  if (def) {
    // 造物：spec.scale 是体型倍率（sdf_prop.ts），改它零成本、瞬时可见、不换资产。
    const spec = def.spec as { scale?: number } | undefined;
    if (spec && typeof spec === 'object') spec.scale = scale;
    store.upsertItem(def);
    const loc = findItemTile(store, worldId, currentScene, itemRef);
    if (loc) {
      // 复用 tile 编辑路径：重发同一 tile 的同一引用（矩阵无实质变化）只为 version+1 触发重铺，
      // forceInclude 把改过 scale 的 def 塞进 patch.items，客户端覆写目录 → rebuild_tiles 按新 scale 重绘。
      try {
        editSceneTerrain(store, hub, worldId, currentScene, [{ x: loc.x, y: loc.y, item: { id: itemRef, yawDeg: loc.yawDeg } }], [itemRef]);
      } catch {
        // 校验意外失败：def 已更新，下次全量对齐或重摆时会按新 scale 渲染，不阻断试用判定。
      }
    }
    return;
  }
  const char = store.getCharacter(worldId, itemRef);
  if (char) {
    char.appearance.size = newSize;
    char.appearance.scale = scale;
    store.saveCharacter(char);
    hub?.broadcastScene(worldId, char.sceneId ?? DEFAULT_SCENE, {
      type: 'character_resized', worldId, sceneId: char.sceneId ?? DEFAULT_SCENE, characterId: itemRef, size: newSize, scale,
    });
  }
}

/**
 * 处理位置上报(JSON positions_report 与二进制帧共用)。空间权威在客户端,服务端记最后 tile 供读回,
 * 并把携 x,y 的条目按【同世界同场景】转发插值 + 喂 near 求值。下行 positions_relay 双格式编码一次:
 * 二进制成员发 bin、其余发 JSON(序列化各一次)。sceneId 空串 = 不覆盖,沿用 session.currentScene(高频流不带)。
 */
export function applyPositionsReport(
  input: { worldId: string; sceneId: string; t?: number; chars: unknown[]; player?: unknown; balls?: unknown[] },
  socket: { send: (data: string) => void },
  store: WorldStore,
  session: VoiceSession,
  connKey: string,
  hub?: WorldHub,
  stages?: StageDirector,
): void {
  const worldId = input.worldId;
  // 明示 sceneId(非空)时以它为准并自愈 session/hub;高频流不带 sceneId → 沿用 session.currentScene。
  if (input.sceneId && input.sceneId !== session.currentScene) {
    session.currentScene = input.sceneId;
    hub?.setScene(connKey, input.sceneId);
  }
  const sceneId = session.currentScene;
  const entries = input.chars;
  let applied = 0;
  const relayChars: { id: string; x: number; y: number }[] = [];
  for (const raw of entries) {
    if (typeof raw !== 'object' || raw === null) continue;
    const e = raw as { id?: unknown; tileX?: unknown; tileY?: unknown; x?: unknown; y?: unknown };
    if (typeof e.id !== 'string' || !e.id) continue;
    const tile: TilePos = { tileX: Number(e.tileX), tileY: Number(e.tileY) };
    if (isValidTile(tile) && store.setCharacterTile(worldId, e.id, tile, sceneId)) applied++;
    if (typeof e.x === 'number' && typeof e.y === 'number') relayChars.push({ id: e.id, x: e.x, y: e.y });
  }
  let relayPlayer: { id: string; x: number; y: number } | undefined;
  if (typeof input.player === 'object' && input.player !== null && session.playerId) {
    const p = input.player as { tileX?: unknown; tileY?: unknown; x?: unknown; y?: unknown };
    const tile: TilePos = { tileX: Number(p.tileX), tileY: Number(p.tileY) };
    if (isValidTile(tile)) store.setPlayerTile(worldId, sceneId, session.playerId, tile);
    if (typeof p.x === 'number' && typeof p.y === 'number') relayPlayer = { id: session.playerId, x: p.x, y: p.y };
  }
  // C 档球（realtime-game-primitives §5）：球位置也进复制流（供他端插值/外推 + 服务端 enter 判定）。
  // 球【不】持久化为角色（无 setCharacterTile）——它是演出道具，收场即散。
  const relayBalls: { id: string; x: number; y: number; vx: number; vy: number }[] = [];
  for (const raw of input.balls ?? []) {
    if (typeof raw !== 'object' || raw === null) continue;
    const e = raw as { id?: unknown; x?: unknown; y?: unknown; vx?: unknown; vy?: unknown };
    if (typeof e.id !== 'string' || !e.id) continue;
    if (typeof e.x !== 'number' || typeof e.y !== 'number') continue;
    relayBalls.push({ id: e.id, x: e.x, y: e.y, vx: Number(e.vx) || 0, vy: Number(e.vy) || 0 });
  }
  if (relayChars.length > 0 || relayPlayer || relayBalls.length > 0) {
    const t = typeof input.t === 'number' ? input.t : 0;
    if (relayBalls.length > 0) {
      // 带球的这一拍走 JSON 广播（二进制 relay 帧 encodeRelay 不含球）；posBin 客户端也解析 JSON
      // positions_relay（_poll_ws 收字符串包走 JSON 分发），故球能到达全端。球只在踢球演出期间出现。
      hub?.broadcastScene(
        worldId, sceneId,
        { type: 'positions_relay', sceneId, t, chars: relayChars, player: relayPlayer, balls: relayBalls },
        connKey,
      );
    } else {
      // 常态高频流：双格式编码各一次（JSON 给老客户端、二进制给 posBin 客户端），别逐接收者重复编。
      const text = JSON.stringify({ type: 'positions_relay', sceneId, t, chars: relayChars, player: relayPlayer });
      const bin = encodeRelay({ t, sceneId, chars: relayChars, player: relayPlayer });
      hub?.broadcastSceneDual(worldId, sceneId, text, bin, connKey);
    }
    const all = relayPlayer ? [...relayChars, relayPlayer] : [...relayChars];
    for (const b of relayBalls) all.push({ id: b.id, x: b.x, y: b.y });
    stages?.updatePositions(worldId, all);
  }
  if (entries.length > 0 && applied === 0) {
    socket.send(JSON.stringify({ type: 'error', error: 'no character position applied' }));
  }
}

export async function handleWsMessage(
  socket: { send: (data: string) => void },
  raw: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  limiter: RateLimiter,
  connKey: string,
  session: VoiceSession,
  hub?: WorldHub,
  stages?: StageDirector,
): Promise<void> {
  // 造角色的降生上下文：取当下所在场景（enter_scene 会改它，故求值而非提前快照）。
  const spawnCtx = (): SpawnCtx => ({ sceneId: session.currentScene, hub, connKey });
  let msg: {
    type?: string;
    worldId?: string;
    intentText?: string;
    byFairy?: boolean;
    characterId?: string;
    slot?: string; // character_attach：贴纸槽位（headTop/handL/handR）
    transcript?: string; // voice_transcript：端侧 ASR 已识别的文本（唯一语音入口）
    text?: string; // tts_request：客户端 edge-tts 失败时求服务端合成的文本
    voiceId?: string; // tts_request：合成音色
    locations?: unknown; // world_info：世界地点名清单
    // 奖赏系统：task_event 完成事件（匹配进行中委托则盖章）
    kind?: string;
    targetName?: string;
    locationName?: string;
    itemId?: string; // item_place：要摆出的物品实体 id（背包持有）；sticker_buy：要买的贴纸 id
    yawDeg?: number; // item_place：摆放朝向（度）
    edgeSide?: number; // item_place/pickup：0..3=N/E/S/W，带上 = 操作 tile 边缘（贴纸）
    tileX?: number;
    tileY?: number;
    // positions_report：客户端批量上报 tile（chars 只含本轮变化过的角色，player 可缺省）
    chars?: unknown;
    player?: unknown;
    balls?: unknown; // C 档球位置流：[{id,x,y,vx,vy}]，转发给同场景他端 + 喂 enter 判定（不持久化）
    // C 档球所有权广播（ball_kick / ball_settle，见 realtime-game-primitives §5）
    ballId?: string;
    x?: number;
    y?: number;
    vx?: number;
    vy?: number;
    /** 玩家当前所在场景（缺省 village；老客户端不带）。 */
    sceneId?: string;
    // positions_report 流式版（演出/多人）：条目带世界坐标 x,y + 服务端钟时戳 t，供转发插值与 near 求值
    t?: number;
    // 引导式造角色：creation_reply 幼儿点的图标 id / 说的话
    optionId?: string;
    spokenText?: string;
    // 积木式造物 B1 复用改装（build_options 取兼容零件 / create_build 直接落成编辑后的零件树）
    blueprintId?: string; // 改哪副蓝图的组合物（客户端读组合物 spec.blueprintId 带上）
    filled?: unknown;     // create_build：编辑后的槽→零件 map（{slotId: partId}），服务端 fit 校验后落成
    // 试用·还差一点（A1）：wish_refine 上报小朋友把造出来那件东西的体型调成了哪档
    itemRef?: string;     // 调的是哪件东西（item id / character id，与 ActiveTask.refineItemRef 对应）
    newSize?: string;     // 调成的体型档（small/medium/big）
    // time_sync：客户端发送时刻(客户端毫秒钟)，原样回带供其算偏移
    t0?: number;
    // stage_event：舞台协议上行(kind 复用上面的字段: ack/abort/near/tap/timer)
    cmdId?: number;
    result?: Record<string, unknown>;
    error?: string;
    subId?: string; // near/tap/timer：触发的订阅 id
    payload?: Record<string, unknown>; // 规则事件负载（注回脚本回调）
    // 玩家互动（player_emote / player_speech，见 docs/player-interaction-design.md）
    targetPlayerId?: string;
    action?: string; // player_emote：动作名（EMOTE_ACTIONS 白名单）
    lang?: string; // player_speech：文本语言（跨语言翻译钩子，缺省 zh）
    // 玩家身份：每条消息可带 playerId（设备端稳定 UUID）；world_info 另带 profile 供首见建档。
    playerId?: string;
    profile?: {
      name?: string;
      nickname?: string;
      gender?: string;
      color?: string;
      spriteAsset?: string;
      createdAt?: string;
      anchors?: unknown; // 设备端自报的贴纸锚点；服务端 sanitizeAnchors 夹紧后落库（design §5）
      device?: DeviceReport; // 设备信息上报（机型/系统等）；服务端另并入 IP/UA
    };
  };
  try {
    msg = JSON.parse(raw);
  } catch {
    socket.send(JSON.stringify({ type: 'error', error: 'invalid json' }));
    return;
  }

  // 玩家身份：记进会话，供后续记忆/Visit 按玩家归属（P3/P4 消费）。
  if (typeof msg.playerId === 'string' && msg.playerId) session.playerId = msg.playerId;

  // 心跳：任意消息刷新活跃时刻（空闲扫描据此判半开连接）；
  // ping 回 pong 并标记本连接会发 ping——只有这类连接才做「超时即断」（见连接层扫描）。
  session.lastSeenMs = Date.now();
  if (msg.type === 'ping') {
    session.pingCapable = true;
    socket.send(JSON.stringify({ type: 'pong' }));
    return;
  }

  // 时间偏移握手：回带 t0 + 服务端毫秒钟。倒计时 HUD 双端读数一致、位置插值时间戳都靠它。
  if (msg.type === 'time_sync') {
    socket.send(JSON.stringify({ type: 'time_sync', t0: typeof msg.t0 === 'number' ? msg.t0 : 0, serverMs: Date.now() }));
    return;
  }

  // 舞台协议上行：命令回执/终止请求，路由给该世界进行中的演出。
  if (msg.type === 'stage_event') {
    const worldId = hub?.worldOf(connKey) ?? msg.worldId ?? '';
    stages?.handleStageEvent(worldId, { kind: msg.kind, cmdId: msg.cmdId, result: msg.result, error: msg.error, subId: msg.subId, payload: msg.payload });
    return;
  }

  // 客户端上报世界地点名（连上 WS 后一次）：喂给意图 LLM，让「去某地」归一到真实地名。
  // 回 world_state 同步贴纸背包与进行中委托（断线重连/重启后客户端补状态）。
  if (msg.type === 'world_info') {
    const worldId = msg.worldId ?? '';
    // 玩家登记：world_info 带 playerId + profile 时 upsert（首见即建档，面向 MMO；无鉴权）。
    // 但只认「有真角色」的档案：name / spriteAsset 至少一个非空。客户端在小朋友还没建角色时
    // 也会带 playerId + 全空字段的 profile 上报（upload_dict 恒返回对象），据此建档会在后台留下
    // 一堆「无立绘」空玩家脏数据（见 test/player_registration.test.ts）——空档一律不 upsert、
    // 也不覆盖已有真实档（断线重连时客户端档案若丢失，服务端记录不被抹掉）。
    if (typeof msg.playerId === 'string' && msg.playerId && msg.profile) {
      const p = msg.profile;
      const anchors = sanitizeAnchors(p.anchors); // 设备端自报，夹紧后随 Player 落库供 presence 转发（design §5）
      const player: Player = {
        id: msg.playerId,
        name: String(p.name ?? ''),
        nickname: String(p.nickname ?? ''),
        gender: String(p.gender ?? ''),
        color: String(p.color ?? ''),
        spriteAsset: String(p.spriteAsset ?? ''),
        createdAt: String(p.createdAt ?? ''),
        ...(anchors ? { anchors } : {}),
      };
      if (player.name !== '' || player.spriteAsset !== '') store.upsertPlayer(player);
    }
    const names = (Array.isArray(msg.locations) ? msg.locations : [])
      .filter((n): n is string => typeof n === 'string' && n.trim().length > 0 && n.length <= 20)
      .map((n) => n.trim())
      .slice(0, 32);
    store.setLocations(worldId, names);
    // 记下进世界的初始场景（缺省 village）；后续 enter_scene 走 portal 时更新。
    session.currentScene = (msg.sceneId ?? DEFAULT_SCENE) || DEFAULT_SCENE;
    // 进世界 = 一段会话（Visit）开始：作会话结束批量抽记忆的边界。
    // 顺带落一份设备快照（activity 记录）：连接层 IP/UA + 客户端上报的机型/系统。
    const device = buildDeviceSnapshot(session, msg.profile?.device);
    startSessionVisit(session, worldId, session.playerId, adapters, store, Date.now(), device);
    // 多人基座：登记进 world 分组；首位进入者为 host（NPC 模拟所有权），换世界时旧世界可能换 host。
    if (hub) {
      const joined = hub.join(worldId, {
        clientId: connKey,
        playerId: session.playerId,
        sceneId: session.currentScene,
        send: (m) => socket.send(JSON.stringify(m)),
        sendText: (s) => socket.send(s),
        posBin: session.posBin,
        // socket 在本函数按 {send:(string)} 窄化(复用于测试 mock);真实 ws socket 收 Uint8Array 二进制帧,故此处收窄转发。
        sendBin: (b) => (socket.send as (d: string | Uint8Array) => void)(b),
      });
      joined.departed?.newHost?.send({ type: 'world_host', isHost: true });
      socket.send(JSON.stringify({ type: 'world_host', isHost: joined.isHost }));
      // presence：拿同场景在场名单 + 向他们宣告自己进场（静止的人也能被看见）。
      announceSceneEntry(hub, store, socket, worldId, session.currentScene, connKey, session.playerId);
    }
    socket.send(JSON.stringify({
      type: 'world_state',
      // 二进制位置流回执：客户端 ?posbin=1 且服务端支持时为 true，客户端据此才切二进制上行(防老服务端)。
      posBin: session.posBin,
      wallet: store.getWallet(worldId, session.playerId),
      // 自己的稳定音色（playerId 哈希）：客户端喊话复述用——复述音=对端听到的音，孩子两端听感一致
      voiceId: session.playerId ? voiceForPlayer(session.playerId, store.getPlayer(session.playerId)?.gender) : '',
      bag: store.getBag(worldId, session.playerId),
      activeTask: store.getActiveTask(worldId, session.playerId),
      // 上次离开时玩家所在 tile（首次进世界 / 老档案无此字段 → 缺省，客户端按点点旁降生）
      playerPos: session.playerId ? store.getPlayerTile(worldId, msg.sceneId ?? DEFAULT_SCENE, session.playerId) : undefined,
    }));
    // 中途加入：世界正在演出时补发 stage_begin，让新连接锁交互并接住后续舞台命令/位置流。
    stages?.snapshotFor(worldId, (m) => socket.send(JSON.stringify(m)));
    // 村民的漏话候选（按这个玩家的 discovered 算）——客户端据此自己调度、按距离衰减地播
    pushWishes(socket, store, worldId, session.playerId, session.currentScene);
    return;
  }

  // 离开世界（前端正常退出显式发）：会话结束，flush 批量抽记忆并收尾 Visit。掉线未发则靠 socket.close 兜底。
  if (msg.type === 'leave_world') {
    session.creation = null; // 离开世界：丢弃未完成的造角色会话
    if (hub) notifyHubLeave(hub, connKey, stages, session.playerId);
    await endSessionVisit(session, adapters, store, Date.now());
    return;
  }

  // 委托完成事件（客户端确定性判定后上报）：匹配进行中委托则盖 1 章（满 3 升 1 花）+ 清任务
  if (msg.type === 'task_event') {
    const worldId = msg.worldId ?? '';
    const done = completeTaskOnEvent(worldId, session.playerId, {
      kind: msg.kind ?? '',
      targetName: msg.targetName,
      locationName: msg.locationName,
    }, store);
    if (done) {
      socket.send(JSON.stringify({
        type: 'task_complete',
        task: done.task,
        stampStyle: done.task.stampStyle,
        flowerGained: done.flowerGained,
        wallet: done.wallet,
      }));
      void pushPraiseTts(socket, adapters, store, worldId, done.task, done, session.clientTts); // 委托人音色的语音表扬（后台合成，不卡庆祝）
    }
    return; // 不匹配静默忽略（迟到/重复上报无副作用）
  }

  if (msg.type === 'create_character_request') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'gen_failed', requestId: randomUUID(), reason: gate.reason }));
      return;
    }
    try {
      await createCharacterAsync(socket, msg.worldId ?? '', session.playerId, msg.intentText ?? '', adapters, store, undefined, session.clientTts, msg.characterId ?? '', spawnCtx());
    } finally {
      gate.release();
    }
    return;
  }

  // 引导式造角色：幼儿点了图标卡（optionId）或说了话（spokenText），推进会话。
  if (msg.type === 'creation_reply') {
    if (!session.creation?.active) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: '没有进行中的造角色会话' }));
      return;
    }
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      // 点选 → 用该选项的中文 label 当输入；否则用语音转写文本。
      const optId = typeof msg.optionId === 'string' ? msg.optionId : '';
      // 积木拼装（build）：点选传的是零件 partId → 直接坐进正在问的槽（服务端权威填槽，不靠 LLM 解析），
      // 再把零件中文名当输入喂 advanceBuild 推进对话（guideBuild 见槽已填即跳到下一个）。
      if (session.creation.goal === 'build') {
        const build = session.creation.build;
        const part = optId ? findPart(optId) : undefined;
        const askedSlot = build?.askedSlots.at(-1);
        if (build && part && askedSlot && !build.filled[askedSlot]) build.filled[askedSlot] = part.id;
        const childInput = (optId ? (part?.name ?? optId) : (msg.spokenText ?? '')).trim();
        if (!childInput) {
          socket.send(JSON.stringify({ type: 'voice_failed', reason: '拼装答复为空' }));
          return;
        }
        await advanceBuild(socket, session, msg.worldId ?? '', msg.characterId ?? '', childInput, adapters, store, '');
        return;
      }
      // 点选 → 该选项中文 label 当输入；造贴纸查贴纸图标库，造物查物品图标库，造角色查角色图标库。
      const lookup = session.creation.goal === 'sticker' ? findStickerOption : session.creation.goal === 'prop' ? findPropOption : findOption;
      const picked = optId ? lookup(optId) : undefined;
      // 点选路径确定性入账：option 自带 category，服务端直接写 attrs，不依赖 LLM 把 label 解析进
      // updatedAttrs——此前解析失败属性不进账，guide 看到的状态不变，就会重复问同一个问题。
      if (picked) {
        const a = session.creation.attrs;
        if (picked.category === 'kind') a.kind = picked.label;
        else if (picked.category === 'color') a.color = picked.label;
        else if (picked.category === 'size') a.size = picked.label;
        else if (picked.category === 'personality') a.personality = picked.label;
        else if (picked.category === 'motion') a.motion = picked.label;
        else if (picked.category === 'trait' && !a.traits.includes(picked.label)) a.traits.push(picked.label);
      }
      const childInput = (optId ? (picked?.label ?? optId) : (msg.spokenText ?? '')).trim();
      if (!childInput) {
        socket.send(JSON.stringify({ type: 'voice_failed', reason: '造角色答复为空' }));
        return;
      }
      await advanceCreation(socket, session, msg.worldId ?? '', msg.characterId ?? '', childInput, adapters, store, '', spawnCtx());
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // 取消造角色（幼儿点别处/退出）：清掉会话，不再把后续语音当造角色答复。
  if (msg.type === 'creation_cancel') {
    session.creation = null;
    return;
  }

  // 试用·还差一点（A1，docs/kids-thinking-tryout-refine.md §4.1/§4.2）：小朋友把造出来那件东西的体型调了一次。
  // ①【应用体型 + 广播重渲染】（老板拍板：服务端改尺寸）——不管这一下调对没调对，孩子按下的这一下都要看得见。
  // ② 判定试用是否满意：方向对/达上限 → 盖章 + 村民用自己音色道谢；方向反且未达上限 → 仙子再问一句更具体的问句。
  if (msg.type === 'wish_refine') {
    const worldId = msg.worldId ?? '';
    const itemRef = String(msg.itemRef ?? '');
    const newSize = (String(msg.newSize ?? 'medium')) as CreatureSize;
    // 先按当前场景把体型落到世界（造物走 terrain_patch 重铺、角色走 character_resized）。
    applyRefineResize(store, hub, worldId, session.currentScene, itemRef, newSize);
    const r = completeWishRefine(worldId, session.playerId, itemRef, newSize, store);
    if (!r) return; // 没有对应试用（不该发生）：静默
    if (r.satisfied) {
      socket.send(JSON.stringify({
        type: 'task_complete', task: r.task, stampStyle: r.task.stampStyle,
        flowerGained: r.flowerGained, wallet: r.wallet,
      }));
      await pushPraiseTts(socket, adapters, store, worldId, r.task, r, session.clientTts);
    } else {
      // 调反了、还没到上限：仙子升一级再问一句（仍是问句，客户端播预制 refine_hint_2）。
      socket.send(JSON.stringify({
        type: 'wish_retry', worldId, npcId: r.task.npcId, itemRef,
        refineDir: r.task.refineDir, tries: r.tries, fairyHint: REFINE_HINT_2,
      }));
    }
    return;
  }

  // 复用改装（B1，§3.1）：客户端进「拆开改改」时取回本蓝图每槽的兼容零件表，本地即时建换槽零件盘。
  // 只读、无会话、不扣花（改装的扣费在 create_build 落成那一刻）。
  if (msg.type === 'build_options') {
    const worldId = msg.worldId ?? '';
    const blueprintId = String(msg.blueprintId ?? '');
    socket.send(JSON.stringify({ type: 'build_options', worldId, blueprintId, options: buildSlotOptions(blueprintId) }));
    return;
  }

  // 复用改装落成（B1，§3.1「无需新机制」）：客户端把编辑后的零件树（blueprintId + filled）直接送来，
  // 服务端 fit 校验后走 createBuildAsync 造一行**新** ItemDef（旧的保留在背包，可拆可复用），无 LLM 会话。
  // 扣花/退还与引导拼装同价（createBuildAsync 内处理）；无仙子引导故 creatorId=''（不记 creation 记忆）。
  if (msg.type === 'create_build') {
    const worldId = msg.worldId ?? '';
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      const blueprintId = String(msg.blueprintId ?? '');
      const raw = (msg.filled && typeof msg.filled === 'object') ? msg.filled as Record<string, unknown> : {};
      const filled: Record<string, string> = {};
      for (const k of Object.keys(raw)) {
        const v = raw[k];
        if (typeof v === 'string' && v) filled[k] = v;
      }
      await createBuildAsync(
        socket, worldId, session.playerId, blueprintId, filled,
        adapters, store, session.clientTts, '', session.currentScene,
      );
    } catch (err) {
      socket.send(JSON.stringify({ type: 'prop_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // ── 端侧 ASR：客户端（Android 插件 / macOS GDExtension）本地识别完成，直送转写文本。
  // 这是唯一的语音入口——服务端 ASR（voice_input 整段、voice_start/chunk/end 流式）已整条退役。──
  if (msg.type === 'voice_transcript') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      const transcript = (msg.transcript ?? '').trim();
      if (!transcript) {
        socket.send(JSON.stringify({ type: 'voice_failed', reason: '转写文本为空' }));
        return;
      }
      // 造角色/物/贴纸/拼装引导会话进行中：这句话当会话答复，不走 routeIntent。积木拼装走 advanceBuild。
      if (session.creation?.active) {
        if (session.creation.goal === 'build') {
          await advanceBuild(socket, session, msg.worldId ?? '', msg.characterId ?? '', transcript, adapters, store, '');
        } else {
          await advanceCreation(socket, session, msg.worldId ?? '', msg.characterId ?? '', transcript, adapters, store, '', spawnCtx());
        }
        return;
      }
    // 流式 TTS 钩子：character_response 先行（文字/行为脚本提前到达），音频分片随合成推送。
    const ttsHooks = {
      onResponse: (r: VoiceResponse) => socket.send(JSON.stringify({ type: 'character_response', ...r })),
      onChunk: (pcm: Uint8Array) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
      onEnd: (assetHash: string) => socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: assetHash })),
    };
      const response = await respondToTranscript(
        msg.worldId ?? '',
        msg.characterId ?? '',
        session.playerId,
        transcript,
        adapters,
        store,
        ttsHooks,
        session.clientTts,
        session.currentScene,
        visitContext(session, msg.characterId ?? ''),
      );
      // 造角色/造物入口：respondToTranscript 识别到意图但没出声，这里开引导会话，不发普通回应。
      if (response.characterRequest) {
        await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.characterRequest, adapters, store, response.replyText, 'character', spawnCtx());
        return;
      }
      if (response.propRequest) {
        // 造物入口升级：孩子要的东西有蓝图（小车/房子/火车/雪人）→ 从「许愿造一个」升级成「亲手拼一个」（积木式造物 B1）。
        // 无蓝图则回落现有整体造物（优雅降级）。docs/kids-thinking-build-from-parts.md §4.1。
        const bp = matchBlueprint(response.propRequest);
        if (bp) {
          await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.propRequest, adapters, store, response.replyText, 'build', spawnCtx(), bp.id);
        } else {
          await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.propRequest, adapters, store, response.replyText, 'prop', spawnCtx());
        }
        return;
      }
      if (response.stickerRequest) {
        await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.stickerRequest, adapters, store, response.replyText, 'sticker', spawnCtx());
        return;
      }
      // 玩游戏入口：生成剧本→过 typecheck→开演（stage_begin 广播全场），不发普通回应。
      if (response.gameRequest) {
        await startGameAsync(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.gameRequest, response.replyText, adapters, store, hub, stages);
        return;
      }
      // 仙子答应带路 = 发现了「引路」玩法（宽松口径：应下就算，不等走到——
      // 中途反悔的 3 岁小朋友不该被剥夺盖章）。若有村民正盼着去哪儿 → 心愿达成。
      if (response.guide) await fulfillAbility(socket, adapters, store, msg.worldId ?? '', session.playerId, 'guide_to', session.clientTts, session.currentScene);
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
      // 对话增量记进当前 Visit；会话结束（leave_world/close）批量抽记忆，省去每轮一次 LLM。
      recordVisitTurn(session, msg.worldId ?? '', session.playerId, msg.characterId ?? '', response.transcript, response.replyText, adapters, store);
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // 进对话对方先开口：客户端进近身、站位就绪后发 voice_greeting，服务端按角色招呼风格随机选一句、
  // 用该角色 voiceId 走流式 TTS 出声（与 respondToTranscript 同一 character_response+tts_chunk 通道）。
  // 招呼是可选点缀：被限流或失败都静默跳过，绝不打断进对话（玩家仍可直接开口）。
  if (msg.type === 'voice_greeting') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) return;
    try {
      const ttsHooks = {
        onResponse: (r: VoiceResponse) => socket.send(JSON.stringify({ type: 'character_response', ...r })),
        onChunk: (pcm: Uint8Array) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
        onEnd: (assetHash: string) => socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: assetHash })),
      };
      const response = await greetCharacter(msg.worldId ?? '', msg.characterId ?? '', adapters, store, ttsHooks, Math.random, session.clientTts);
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
    } catch (err) {
      console.warn(`招呼失败（静默跳过，不打断进对话）：${String(err)}`);
    } finally {
      gate.release();
    }
    return;
  }

  // clientTts 逐句降级口：客户端 edge-tts 合成失败时，把文本+voiceId 发回来走服务端合成。
  // 回 tts_start（带 mime）+ tts_chunk×N + tts_end——独立于 character_response，不触发客户端气泡/情绪副作用。
  // 不落 TTS 资产（降级句无历史回放需求）。失败回 tts_failed，客户端静默放弃本句。
  if (msg.type === 'tts_request') {
    const text = (msg.text ?? '').trim();
    if (!text) return;
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'tts_failed', reason: gate.reason }));
      return;
    }
    try {
      const voiceId = msg.voiceId ?? '';
      const streamFn = adapters.tts.synthesizeStream?.bind(adapters.tts);
      if (streamFn) {
        await streamFn(text, voiceId, {
          onStart: (mime) => socket.send(JSON.stringify({ type: 'tts_start', ttsMime: mime })),
          onChunk: (pcm) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
        });
      } else {
        const audio = await adapters.tts.synthesize(text, voiceId);
        socket.send(JSON.stringify({ type: 'tts_start', ttsMime: audio.mime }));
        socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(audio.bytes).toString('base64') }));
      }
      socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: '' }));
    } catch (err) {
      socket.send(JSON.stringify({ type: 'tts_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // 摆放：背包扣一份 → 目标 tile 挂实体引用（唯一写入口 editSceneTerrain：校验 →
  // version+1 → terrain_patch 广播，发起者也靠广播落地渲染）。失败回 error 不动账。
  // 带 edgeSide（0..3=N/E/S/W）= 贴纸挂 tile 边缘（sticker-items 设计 §2.2），不带 = 摆 tile 正上方。
  if (msg.type === 'item_place') {
    const worldId = msg.worldId ?? '';
    const itemId = msg.itemId ?? '';
    const sceneId = session.currentScene || DEFAULT_SCENE;
    const x = Math.trunc(Number(msg.tileX ?? -1));
    const y = Math.trunc(Number(msg.tileY ?? -1));
    const edgeSide = msg.edgeSide === undefined ? null : Math.trunc(Number(msg.edgeSide));
    if ((store.getBag(worldId, session.playerId)[itemId] ?? 0) < 1) {
      socket.send(JSON.stringify({ type: 'error', error: 'item not in bag' }));
      return;
    }
    // tile 编辑对已有引用是覆写语义（admin 用）；摆放不许顶掉别人——目标 tile/边必须为空。
    // footprint 级冲突（压进民居占地等）与 mount 错位由 editSceneTerrain 整图复检兜住。
    const occupied = edgeSide === null
      ? tileItemIdAt(store, worldId, sceneId, x, y) !== ''
      : tileEdgeItemIdAt(store, worldId, sceneId, x, y, edgeSide) !== '';
    if (occupied) {
      socket.send(JSON.stringify({ type: 'error', error: edgeSide === null ? 'tile occupied' : 'edge occupied' }));
      return;
    }
    try {
      const edit = edgeSide === null
        ? { x, y, item: { id: itemId, yawDeg: Number(msg.yawDeg ?? 0) } }
        : { x, y, edge: { side: edgeSide, id: itemId } };
      editSceneTerrain(store, hub, worldId, sceneId, [edit]);
    } catch (err) {
      socket.send(JSON.stringify({ type: 'error', error: err instanceof Error ? err.message : String(err) }));
      return;
    }
    store.bagTake(worldId, session.playerId, itemId);
    socket.send(JSON.stringify({ type: 'bag_update', worldId, bag: store.getBag(worldId, session.playerId) }));
    return;
  }

  // 拾起：tile 上的引用必须是语音造物（实体 worldId 非空）——内置树/石/建筑拒拾。
  // 例外：边缘贴纸（mount:'edge'）虽是内置也允许拾回——孩子贴错要能揭下来（老板拍板 2026-07-12）。
  // 清引用（terrain_patch 广播）→ 背包加一份 → bag_update。失败回 error 不动账。
  if (msg.type === 'item_pickup') {
    const worldId = msg.worldId ?? '';
    const sceneId = session.currentScene || DEFAULT_SCENE;
    const x = Math.trunc(Number(msg.tileX ?? -1));
    const y = Math.trunc(Number(msg.tileY ?? -1));
    const edgeSide = msg.edgeSide === undefined ? null : Math.trunc(Number(msg.edgeSide));
    const itemId = edgeSide === null
      ? tileItemIdAt(store, worldId, sceneId, x, y)
      : tileEdgeItemIdAt(store, worldId, sceneId, x, y, edgeSide);
    const def = itemId ? store.getItemDef(worldId, itemId) : undefined;
    if (!def) {
      socket.send(JSON.stringify({ type: 'error', error: edgeSide === null ? 'no item on tile' : 'no item on edge' }));
      return;
    }
    if (def.worldId === null && def.mount !== 'edge') {
      socket.send(JSON.stringify({ type: 'error', error: 'builtin item not pickable' }));
      return;
    }
    try {
      const edit = edgeSide === null ? { x, y, item: null } : { x, y, edge: { side: edgeSide, id: null } };
      editSceneTerrain(store, hub, worldId, sceneId, [edit]);
    } catch (err) {
      socket.send(JSON.stringify({ type: 'error', error: err instanceof Error ? err.message : String(err) }));
      return;
    }
    store.bagAdd(worldId, session.playerId, itemId);
    socket.send(JSON.stringify({ type: 'bag_update', worldId, bag: store.getBag(worldId, session.playerId) }));
    return;
  }

  // 贴纸小铺：小红花买贴纸进背包（sticker-items 设计 §2.3，单价 1 朵）。
  // 只卖内置贴纸（mount:'edge'）；余额不足回 sticker_denied（同 gen/prop_denied 心智）。
  if (msg.type === 'sticker_buy') {
    const worldId = msg.worldId ?? '';
    const itemId = msg.itemId ?? '';
    const def = getBuiltinItem(itemId);
    if (!def || def.mount !== 'edge') {
      socket.send(JSON.stringify({ type: 'error', error: 'not a sticker' }));
      return;
    }
    if (!store.spendFlower(worldId, session.playerId)) {
      socket.send(JSON.stringify({
        type: 'sticker_denied', worldId, reason: 'no_flowers',
        wallet: store.getWallet(worldId, session.playerId),
      }));
      return;
    }
    store.bagAdd(worldId, session.playerId, itemId);
    socket.send(JSON.stringify({
      type: 'sticker_bought', worldId, itemId,
      bag: store.getBag(worldId, session.playerId),
      wallet: store.getWallet(worldId, session.playerId),
    }));
    return;
  }

  // 贴角色贴纸：挂/摘（character-anchors §5）。贴上=背包扣一份，摘下=回背包，
  // 同槽已有=旧的回背包换新（替换语义）。落库角色行，经 WorldHub 按角色所在场景
  // 定向广播 character_attach——发起者也靠广播落地渲染（与 terrain_patch 同哲学）。
  if (msg.type === 'character_attach') {
    const worldId = msg.worldId ?? '';
    const characterId = msg.characterId ?? '';
    const slot = String(msg.slot ?? '');
    const itemId = msg.itemId === undefined || msg.itemId === null || msg.itemId === '' ? null : String(msg.itemId);
    if (slot !== 'headTop' && slot !== 'handL' && slot !== 'handR') {
      socket.send(JSON.stringify({ type: 'error', error: 'bad slot' }));
      return;
    }
    const char = store.getCharacter(worldId, characterId);
    if (!char) {
      socket.send(JSON.stringify({ type: 'error', error: 'character not found' }));
      return;
    }
    const list = char.attachments ?? [];
    const existing = list.find((a) => a.slot === slot);
    if (itemId !== null) {
      const def = getBuiltinItem(itemId);
      if (!def || def.mount !== 'edge') {
        socket.send(JSON.stringify({ type: 'error', error: 'not a sticker' }));
        return;
      }
      if ((store.getBag(worldId, session.playerId)[itemId] ?? 0) < 1) {
        socket.send(JSON.stringify({ type: 'error', error: 'item not in bag' }));
        return;
      }
      store.bagTake(worldId, session.playerId, itemId);
      if (existing) {
        store.bagAdd(worldId, session.playerId, existing.itemId); // 换装：旧贴纸回背包
        existing.itemId = itemId;
        char.attachments = list;
      } else {
        char.attachments = [...list, { slot, itemId }];
      }
    } else {
      if (!existing) {
        socket.send(JSON.stringify({ type: 'error', error: 'slot empty' }));
        return;
      }
      store.bagAdd(worldId, session.playerId, existing.itemId);
      char.attachments = list.filter((a) => a.slot !== slot);
    }
    store.saveCharacter(char);
    hub?.broadcastScene(worldId, char.sceneId ?? DEFAULT_SCENE, {
      type: 'character_attach', worldId, sceneId: char.sceneId ?? DEFAULT_SCENE, characterId, slot, itemId,
    });
    socket.send(JSON.stringify({ type: 'bag_update', worldId, bag: store.getBag(worldId, session.playerId) }));
    return;
  }

  // 走 portal 换场景（模型 B）：换 session.currentScene，回该场景的地形 hash + 角色 + pois +
  // 该场景里玩家的最后位置。客户端据此卸载旧场景、载入新场景。scene 为 null 表示该场景还没入库
  // （客户端回退本地生成或忽略）。角色按场景过滤；摆着的造物在场景矩阵里，不再单发。
  if (msg.type === 'enter_scene') {
    const worldId = msg.worldId ?? '';
    const sceneId = (msg.sceneId ?? DEFAULT_SCENE) || DEFAULT_SCENE;
    const prevScene = session.currentScene;
    session.currentScene = sceneId;
    // 走 portal：先跟旧场景的人告别（他们要即时清掉我的副本），再把 hub 里的场景切过去，
    // 位置流/降生广播才会按新场景定向。
    if (hub && prevScene !== sceneId) {
      if (session.playerId) {
        hub.broadcastScene(worldId, prevScene, { type: 'actor_leave', playerId: session.playerId, sceneId: prevScene }, connKey);
      }
      hub.setScene(connKey, sceneId);
      announceSceneEntry(hub, store, socket, worldId, sceneId, connKey, session.playerId);
    }
    const scene = store.getScene(worldId, sceneId);
    socket.send(JSON.stringify({
      type: 'scene_entered',
      worldId,
      sceneId,
      scene: scene ?? null,
      characters: store.listCharacters(worldId, sceneId),
      // 物品实体定义（内置+造物）：新场景矩阵 palette 的解引用依据
      items: [...BUILTIN_ITEMS, ...store.listWorldItems(worldId)],
      playerPos: session.playerId ? store.getPlayerTile(worldId, sceneId, session.playerId) : undefined,
    }));
    pushWishes(socket, store, worldId, session.playerId, sceneId); // 换场景 = 换了一批村民
    return;
  }

  // 角色/玩家坐标回报：空间权威在客户端，服务端只记最后位置供下次进世界读回。
  // 静止时客户端不发；每拍只带 tile 变化过的角色。越界 tile 静默丢弃（单个坏条目不连坐整批）。
  if (msg.type === 'positions_report') {
    applyPositionsReport(
      { worldId: msg.worldId ?? '', sceneId: typeof msg.sceneId === 'string' ? msg.sceneId : '', t: msg.t, chars: Array.isArray(msg.chars) ? msg.chars : [], player: msg.player, balls: Array.isArray(msg.balls) ? msg.balls : [] },
      socket, store, session, connKey, hub, stages,
    );
    return;
  }

  // 玩家互动（见 docs/player-interaction-design.md）：emote=打招呼动作，speech=ASR 文本中继对话。
  // 服务端无状态：校验后按【同世界同场景】定向转发，不落库。speech 是「喊话」模型——
  // 同场景旁观者也收到（现实里说话旁边人也听得见）；lang 字段是将来跨语言翻译的钩子。
  if (msg.type === 'player_emote') {
    if (!hub || !session.playerId) return; // 无多人基座/无身份：没有可送达的对象
    const action = String(msg.action ?? '');
    if (!EMOTE_ACTIONS.has(action)) {
      socket.send(JSON.stringify({ type: 'error', error: `unknown emote action: ${action}` }));
      return;
    }
    const worldId = msg.worldId ?? '';
    const target = typeof msg.targetPlayerId === 'string' ? msg.targetPlayerId : '';
    hub.broadcastScene(worldId, session.currentScene, {
      type: 'player_emote',
      sceneId: session.currentScene,
      fromPlayerId: session.playerId,
      targetPlayerId: target,
      action,
    }, connKey);
    // 送❤入账：收方爱心 +1（只增不减、不动小红花）。离线/跨场景也入账——孩子的心意不丢；
    // 收方在线则单播最新钱包（hearts_update），集邮册立即点亮。
    if (action === 'heart' && target && target !== session.playerId) {
      const w = store.addHeart(worldId, target);
      for (const m of hub.membersIn(worldId)) {
        if (m.playerId === target) m.send({ type: 'hearts_update', wallet: w });
      }
    }
    return;
  }

  if (msg.type === 'player_speech') {
    if (!hub || !session.playerId) return;
    // 长度封顶：ASR 单句不会超过这个数，超长=异常客户端，截断而不是拒绝（孩子的话不该整句丢掉）。
    const text = String(msg.text ?? '').trim().slice(0, 200);
    if (!text) return; // 空句（ASR 没识别出内容）没有转发价值
    hub.broadcastScene(msg.worldId ?? '', session.currentScene, {
      type: 'player_speech',
      sceneId: session.currentScene,
      fromPlayerId: session.playerId,
      targetPlayerId: typeof msg.targetPlayerId === 'string' ? msg.targetPlayerId : '',
      text,
      lang: typeof msg.lang === 'string' && msg.lang ? msg.lang : 'zh',
      // 音色由服务端盖章（而非收端查 presence）：收端在 actor_join 之前收到喊话也能出对的声。
      voiceId: voiceForPlayer(session.playerId, store.getPlayer(session.playerId)?.gender),
    }, connKey);
    return;
  }

  // C 档球所有权广播（realtime-game-primitives §5）：无状态、按【同世界同场景】定向转发（排除自己），不落库。
  // ball_kick=踢者转所有权给自己 + 携速度供他端外推；ball_settle=滚停交回 host 中立。
  if (msg.type === 'ball_kick' || msg.type === 'ball_settle') {
    if (!hub || !session.playerId) return; // 无多人基座/无身份：没有可送达的对象
    const ballId = typeof msg.ballId === 'string' ? msg.ballId : '';
    if (!ballId) return;
    const relay: Record<string, unknown> = {
      type: msg.type,
      sceneId: session.currentScene,
      ballId,
      x: Number(msg.x) || 0,
      y: Number(msg.y) || 0,
      t: msg.t,
    };
    if (msg.type === 'ball_kick') {
      relay.playerId = session.playerId; // 服务端盖章踢者身份（各端据此转所有权）
      relay.vx = Number(msg.vx) || 0;
      relay.vy = Number(msg.vy) || 0;
    }
    hub.broadcastScene(msg.worldId ?? '', session.currentScene, relay, connKey);
    return;
  }

  // 退役协议（服务端 ASR，2026-07-13）：老客户端可能仍发音频会话消息。静默忽略而不是落到下面的
  // unknown type——voice_chunk 是 150ms 一片的高频消息，逐片回 error 等于给老客户端刷一场 error 风暴。
  // 注意：老客户端发完 voice_end 会一直等不到 character_response（服务端不再识别音频），
  // 由它自己的思考超时解卡。真机一律走端侧 ASR（voice_transcript），不受影响。
  if (RETIRED_VOICE_TYPES.has(msg.type ?? '')) return;

  socket.send(JSON.stringify({ type: 'error', error: `unknown type: ${msg.type}` }));
}
