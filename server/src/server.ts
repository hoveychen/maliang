import { randomUUID } from 'node:crypto';
import { existsSync } from 'node:fs';
import path from 'node:path';
import Fastify, { type FastifyInstance } from 'fastify';
import websocket from '@fastify/websocket';
import fastifyStatic from '@fastify/static';
import type { ServiceAdapters, ASRStream } from './adapters/types.ts';
import { createAdapters } from './adapters/factory.ts';
import { loadConfig } from './config.ts';
import { WorldStore } from './persistence.ts';
import { createCharacter, generateSprite, generateIconAsset, ModerationError } from './orchestrator.ts';
import { trimToContent } from './adapters/chroma_cutout.ts';
import { generateIdleAnimation, triggerIdleAnimation, backfillIdleAnimations, type ToSpriteSheet } from './idle_animation.ts';
import type { SpriteSheetMeta } from './sprite_sheet.ts';
import { FAIRY_VISUAL_DESC } from './adapters/sprite_style.ts';
import { respondToTranscript, greetCharacter, flushMemory } from './voice.ts';
import { validateSdfPropSpec } from './sdf_prop.ts';
import { RateLimiter } from './ratelimit.ts';
import { registerDebugApi } from './debug_api.ts';
import { newCreationState, isValidTile, ANON_PLAYER, INITIAL_FLOWERS, WORLD_CENTER_TILE, type ActiveTask, type Character, type CreationState, type Player, type TilePos, type VoiceResponse, type Wallet, type WorldProp } from './types.ts';
import { CREATION_OPTIONS, findOption, iconPrompt } from './creation_options.ts';
import { completeTaskOnEvent, flowerDeniedLine, praiseLine } from './tasks.ts';
import { backfillVoices, FAIRY_VOICE } from './voice_catalog.ts';

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

/** 在世界中央种一个小神仙（默认能造角色）。 */
function seedFairy(worldId: string): Character {
  return {
    id: randomUUID(),
    worldId,
    isFairy: true,
    name: '小神仙',
    personality: '温柔的小神仙，能按小朋友的想法创造新伙伴。',
    voiceId: FAIRY_VOICE,
    appearance: { visualDescription: FAIRY_VISUAL_DESC, spriteAsset: '', scale: 1.2 },
    memory: [],
    chatHistory: [],
    state: 'idle',
    behaviorScript: { commands: [{ type: 'wait', params: { duration: 1 } }], loop: true },
    position: WORLD_CENTER_TILE,
    abilities: ['move_to', 'deliver_message', 'create_character', 'create_prop'],
    relationships: {},
  };
}

function characterListView(store: WorldStore, worldId: string) {
  return store.listCharacters(worldId);
}

/** 只读后台快照（P6）：玩家 + 每个世界的角色（含记忆/对话）+ 物件 + Visit。直连 WorldStore，不改状态。 */
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
      props: store.listProps(w.id),
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
    h += '<h4 style="margin:10px 0 2px">物件 ('+w.props.length+') · Visit ('+w.visits.length+')</h4>';
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

  // 新建世界（种入小神仙）
  app.post('/worlds', async () => {
    const world = store.createWorld();
    store.addCharacter(seedFairy(world.id));
    return { id: world.id, characters: characterListView(store, world.id) };
  });

  // 拉世界状态。固定的 "default" 世界不存在时自动创建并种入小神仙
  // （初始村民由 seed 脚本生成；客户端默认加载 default 世界）。
  app.get<{ Params: { id: string } }>('/worlds/:id', async (req, reply) => {
    let world = store.getWorld(req.params.id);
    if (!world && req.params.id === 'default') {
      world = store.createWorld('default');
      store.addCharacter(seedFairy('default'));
    }
    if (!world) return reply.code(404).send({ error: 'world not found' });
    return { id: world.id, characters: characterListView(store, world.id), props: store.listProps(world.id) };
  });

  // 为世界里的小神仙补一张真实 sprite。幂等：已有则跳过；?force=true 强制重生成；
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
    const hash = provided
      ? store.putAsset({ bytes: Uint8Array.from(Buffer.from(provided, 'base64')), mime: 'image/png' })
      : await generateSprite(adapters, FAIRY_VISUAL_DESC, store);
    fairy.appearance.spriteAsset = hash;
    fairy.appearance.visualDescription = FAIRY_VISUAL_DESC;
    store.saveCharacter(fairy);
    // 试点：静态立绘先返回，idle 动画后台异步补（客户端轮询 /sprite-anim/:hash）
    triggerIdleAnimation(adapters, store, hash, toSpriteSheet);
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
      const hash = await generateSprite(adapters, desc, store);
      char.appearance.spriteAsset = hash;
      store.saveCharacter(char);
      return { id: char.id, name: char.name, prev, spriteAsset: hash };
    },
  );

  // 管理端点：把某世界的小红花数直接设为指定值（缺省 INITIAL_FLOWERS）。
  // 共享 default 世界初始额度被造角色/造物花光后，用它补花便于测试（不改经济规则）。
  // 只动 flowers，盖章进度保留。必须配 MALIANG_ADMIN_TOKEN。
  app.post<{ Params: { id: string }; Body: { flowers?: number } | null }>(
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
      const wallet = store.setFlowers(req.params.id, ANON_PLAYER, n);
      return { id: req.params.id, wallet };
    },
  );

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
            triggerIdleAnimation(adapters, store, hash, toSpriteSheet);
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
    const hash = await generateSprite(adapters, desc, store);
    // 试点：玩家形象静态先返回，idle 动画后台异步补（客户端凭 spriteAsset 轮询 /sprite-anim/:hash）
    triggerIdleAnimation(adapters, store, hash, toSpriteSheet);
    return { spriteAsset: hash };
  });

  // onboarding 自我介绍：转写（客户端直送或送 PCM 走服务端 ASR）→ LLM 提取名字/称呼
  // → TTS 复述确认音频。提取不到名字返回空串，客户端播预制 retry 重问（多轮）。
  app.post<{
    Body: { transcript?: string; pcmBase64?: string; rate?: number } | null;
  }>('/onboarding/intro', { bodyLimit: 8 * 1024 * 1024 }, async (req) => {
    let transcript = (req.body?.transcript ?? '').trim();
    if (transcript.length === 0 && req.body?.pcmBase64) {
      const bytes = Uint8Array.from(Buffer.from(req.body.pcmBase64, 'base64'));
      const mime = `audio/L16;rate=${req.body.rate ?? 16000}`;
      transcript = (await adapters.asr.transcribe({ bytes, mime })).trim();
    }
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

  // 取生成的 sprite 资源
  app.get<{ Params: { hash: string } }>('/assets/:hash', async (req, reply) => {
    const asset = store.getAsset(req.params.hash);
    if (!asset) return reply.code(404).send({ error: 'asset not found' });
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
    void generateIdleAnimation(adapters, store, req.params.hash, toSpriteSheet);
    return { spriteHash: req.params.hash, status: 'pending', triggered: true };
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

  // 昂贵操作限流：每连接 N/分钟 + 全局并发上限（防刷付费 API）
  const limiter = new RateLimiter(
    Number(process.env.RATE_PER_MIN ?? 8),
    Number(process.env.RATE_GLOBAL_MAX ?? 4),
  );

  // WebSocket：造角色请求 → 进度推送 → 完成/失败
  app.get('/ws', { websocket: true }, (socket, req) => {
    const connKey = randomUUID(); // 每连接一个限流 key
    const session = newVoiceSession(); // 边录边传：本连接的语音分片缓冲
    // 能力协商：客户端自带 TTS（edge-tts）时连接 URL 带 ?clientTts=1，本连接全程跳过服务端合成。
    session.clientTts = (req.query as { clientTts?: string } | undefined)?.clientTts === '1';
    socket.on('message', (raw: Buffer) => {
      void handleWsMessage(socket, raw.toString(), adapters, store, limiter, connKey, session);
    });
    // 连接断开时释放可能仍持有的限流名额（录到一半断线），并 flush 会话记忆兜底（前端没发 leave_world 就掉线）
    socket.on('close', () => {
      if (session.gate) { session.gate.release(); session.gate = null; }
      session.active = false;
      void endSessionVisit(session, adapters, store, Date.now());
    });
  });

  // 存量回填：把造角色流程上线前预种的村民补上 idle 动画（fire-and-forget，只在真实进程开，不阻塞启动）。
  if (deps.backfillOnBoot) {
    const n = backfillIdleAnimations(adapters, store, toSpriteSheet);
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
}

/** 边说边识别的单连接语音会话：voice_start 开讯飞流，voice_chunk 随到随发，voice_end finish 拿转写走 respondToTranscript。 */
export interface VoiceSession {
  active: boolean;
  worldId: string;
  characterId: string;
  /** 当前玩家 id（设备端稳定 UUID，随消息上报）：供记忆/Visit 按玩家归属（P3/P4 消费）。 */
  playerId: string;
  asr: ASRStream | null;
  gate: { release: () => void } | null;
  /** 进行中的会话（world_info 起、leave_world/close 收尾）；每轮对话增量累积其中，结束批量抽记忆。 */
  visit: VisitState | null;
  /** 进行中的引导式造角色会话（对小仙子说造角色即开启）；期间语音/点选都当造角色答复，见 advanceCreation。 */
  creation: CreationState | null;
  /** 客户端自带 TTS（edge-tts 直连微软）：WS 连接 URL 带 ?clientTts=1 时置位，服务端全程跳过合成只发文本+voiceId。 */
  clientTts: boolean;
}

export function newVoiceSession(): VoiceSession {
  return { active: false, worldId: '', characterId: '', playerId: '', asr: null, gate: null, visit: null, creation: null, clientTts: false };
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
): void {
  if (session.visit) void endSessionVisit(session, adapters, store, now); // 收尾旧的（同步排空 pending，抽取后台跑）
  session.visit = { id: store.startVisit(worldId, playerId, now), worldId, playerId, pending: new Map() };
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
    session.visit = { id: store.startVisit(worldId, playerId, Date.now()), worldId, playerId, pending: new Map() };
  }
  const visit = session.visit;
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

/** 造物/造角色余额检查：至少 1 朵小红花才放行。 */
function hasFlower(store: WorldStore, worldId: string): boolean {
  return store.getWallet(worldId, ANON_PLAYER).flowers >= 1;
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
  kind: 'prop' | 'character',
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
    type: kind === 'prop' ? 'prop_denied' : 'gen_denied',
    reason: 'no_flowers',
    message: line,
    ttsAsset,
    voiceId: fairy?.voiceId ?? '',
    wallet: store.getWallet(worldId, ANON_PLAYER),
  }));
}

/** 造角色引导会话入口：先卡余额（0 花不进会话，仙子引导），够花再开会话推进第一轮。 */
async function openCreationSession(
  socket: { send: (data: string) => void },
  session: VoiceSession,
  worldId: string,
  fairyId: string,
  request: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  leadIn = '', // 入口那轮 routeIntent 生成的仙子应答句（缺陷 ②：此前被丢弃）
): Promise<void> {
  if (!hasFlower(store, worldId)) {
    await denyForNoFlowers(socket, adapters, store, worldId, 'character', session.clientTts);
    return;
  }
  session.creation = newCreationState();
  await advanceCreation(socket, session, worldId, fairyId, request, adapters, store, leadIn);
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

/** create_prop 异步落地：扣 1 花 → 审核 → LLM 设计 spec → 校验 → 持久化 → prop_created 推送。
 *  0 花拦截推 prop_denied；任何失败（审核/校验/异常）都退还那朵花并推 prop_failed。 */
export async function createPropAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  clientTts = false,
): Promise<void> {
  if (!store.spendFlower(worldId, ANON_PLAYER)) {
    await denyForNoFlowers(socket, adapters, store, worldId, 'prop', clientTts);
    return;
  }
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
    const prop: WorldProp = { id: randomUUID(), spec: validated.spec, tile: null, state: 'placed' };
    store.addProp(worldId, prop);
    created = true;
    socket.send(JSON.stringify({ type: 'prop_created', worldId, prop, wallet: store.getWallet(worldId, ANON_PLAYER) }));
  } catch (err) {
    socket.send(JSON.stringify({ type: 'prop_failed', reason: String(err) }));
  } finally {
    if (!created) store.refundFlower(worldId, ANON_PLAYER); // 造失败/被审核挡：退还，别让孩子白花一朵
  }
}

/** create_character 异步落地：造角色管线（spec→审核→生图→抠图→持久化），gen_progress 逐阶段推、
 *  完成 gen_complete、失败 gen_failed。与 create_character_request 复用同一实现；语音触发时不自带 gate
 *  （语音回合已在上层限流，与 createPropAsync 一致）。 */
export async function createCharacterAsync(
  socket: { send: (data: string) => void },
  worldId: string,
  description: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  toSpriteSheet?: ToSpriteSheet,
  clientTts = false,
): Promise<void> {
  if (!store.spendFlower(worldId, ANON_PLAYER)) {
    await denyForNoFlowers(socket, adapters, store, worldId, 'character', clientTts);
    return;
  }
  const requestId = randomUUID();
  let created = false;
  try {
    const character = await createCharacter(
      { worldId, intentText: description, byFairy: true },
      adapters,
      store,
      (stage) => socket.send(JSON.stringify({ type: 'gen_progress', requestId, stage })),
    );
    created = true;
    socket.send(JSON.stringify({ type: 'gen_complete', requestId, character, wallet: store.getWallet(worldId, ANON_PLAYER) }));
    // 静态立绘先给客户端，idle 动画后台异步补（客户端凭 spriteAsset 轮询 /sprite-anim/:hash）
    if (character.appearance.spriteAsset) {
      triggerIdleAnimation(adapters, store, character.appearance.spriteAsset, toSpriteSheet);
    }
  } catch (err) {
    const reason = err instanceof ModerationError ? err.message : String(err);
    socket.send(JSON.stringify({ type: 'gen_failed', requestId, reason }));
  } finally {
    if (!created) store.refundFlower(worldId, ANON_PLAYER); // 造失败：退还，别让孩子白花一朵
  }
}

/**
 * 引导式造角色图标批量生成（P3）：遍历图标库每个选项，走图标专用管线 generateIconAsset
 * （图标画风生图→抠图→程序加白 die-cut 边→putAsset）出一张图，存「option id→asset hash」映射。
 * 幂等：已生成的跳过，除非 force。opts.only 限定只生成指定 id（低成本验证画风）。
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
  for (const o of CREATION_OPTIONS) {
    if (onlySet && !onlySet.has(o.id)) continue;
    if (!opts.force && store.getCreationIcon(o.id)) {
      skipped.push(o.id);
      continue;
    }
    try {
      const hash = await generateIconAsset(adapters, iconPrompt(o.id), store);
      store.setCreationIcon(o.id, hash);
      generated.push(o.id);
    } catch (err) {
      console.warn(`造角色图标生成失败（${o.id}，跳过）：${String(err)}`);
      failed.push(o.id);
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
export async function advanceCreation(
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
  if (!state) return;
  const fairyVoice = store.getCharacter(worldId, fairyId)?.voiceId ?? FAIRY_VOICE;
  let r;
  try {
    r = await adapters.llm.guideCreation(state, childInput);
  } catch (err) {
    // guideCreation 挂了：用现有属性兜底造，不让幼儿卡住
    console.warn(`guideCreation 失败，用现有属性兜底造：${String(err)}`);
    session.creation = null;
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await createCharacterAsync(socket, worldId, describeCreationAttrs(state) || childInput, adapters, store, undefined, session.clientTts);
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
    if (u.traits) state.attrs.traits = u.traits;
  }
  if (r.category) state.askedCategories.push(r.category);
  state.turnCount += 1;
  if (r.done) {
    session.creation = null;
    // 快捷路径：一句说全、首轮即造。没有问句可以搭载，前置话语单独念出来，别吞掉。
    if (leadIn) await pushLineTts(socket, adapters, store, leadIn, fairyVoice, session.clientTts);
    await createCharacterAsync(socket, worldId, r.description || describeCreationAttrs(state) || childInput, adapters, store, undefined, session.clientTts);
    return;
  }
  // 追问：合成仙子问句 TTS（失败不阻塞；clientTts 时客户端自己合成）+ 下发图标选项卡
  const options = (r.optionIds ?? [])
    .map((id) => findOption(id))
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
    replyText: spoken,
    question: r.question ?? r.replyText, // 纯问句：客户端拿它做选项卡标题，不带前置话语
    category: r.category,
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

export async function handleWsMessage(
  socket: { send: (data: string) => void },
  raw: string,
  adapters: ServiceAdapters,
  store: WorldStore,
  limiter: RateLimiter,
  connKey: string,
  session: VoiceSession,
): Promise<void> {
  let msg: {
    type?: string;
    worldId?: string;
    intentText?: string;
    byFairy?: boolean;
    characterId?: string;
    audio?: string; // base64
    format?: string;
    transcript?: string; // voice_transcript：端侧 ASR 已识别的文本
    text?: string; // tts_request：客户端 edge-tts 失败时求服务端合成的文本
    voiceId?: string; // tts_request：合成音色
    locations?: unknown; // world_info：世界地点名清单
    // 奖赏系统：task_event 完成事件（匹配进行中委托则盖章）
    kind?: string;
    targetName?: string;
    locationName?: string;
    propId?: string; // prop_place：语音生成物件的落位回报
    tileX?: number;
    tileY?: number;
    // positions_report：客户端批量上报 tile（chars 只含本轮变化过的角色，player 可缺省）
    chars?: unknown;
    player?: unknown;
    // 引导式造角色：creation_reply 幼儿点的图标 id / 说的话
    optionId?: string;
    spokenText?: string;
    // 玩家身份：每条消息可带 playerId（设备端稳定 UUID）；world_info 另带 profile 供首见建档。
    playerId?: string;
    profile?: {
      name?: string;
      nickname?: string;
      gender?: string;
      color?: string;
      spriteAsset?: string;
      createdAt?: string;
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

  // 客户端上报世界地点名（连上 WS 后一次）：喂给意图 LLM，让「去某地」归一到真实地名。
  // 回 world_state 同步贴纸背包与进行中委托（断线重连/重启后客户端补状态）。
  if (msg.type === 'world_info') {
    const worldId = msg.worldId ?? '';
    // 玩家登记：world_info 带 playerId + profile 时 upsert（首见即建档，面向 MMO；无鉴权）
    if (typeof msg.playerId === 'string' && msg.playerId && msg.profile) {
      const p = msg.profile;
      const player: Player = {
        id: msg.playerId,
        name: String(p.name ?? ''),
        nickname: String(p.nickname ?? ''),
        gender: String(p.gender ?? ''),
        color: String(p.color ?? ''),
        spriteAsset: String(p.spriteAsset ?? ''),
        createdAt: String(p.createdAt ?? ''),
        // profile 不带位置：整对象 upsert 会抹掉已上报的 tile，显式沿用旧值。
        position: store.getPlayer(msg.playerId)?.position,
      };
      store.upsertPlayer(player);
    }
    const names = (Array.isArray(msg.locations) ? msg.locations : [])
      .filter((n): n is string => typeof n === 'string' && n.trim().length > 0 && n.length <= 20)
      .map((n) => n.trim())
      .slice(0, 32);
    store.setLocations(worldId, names);
    // 进世界 = 一段会话（Visit）开始：作会话结束批量抽记忆的边界。
    startSessionVisit(session, worldId, session.playerId, adapters, store, Date.now());
    socket.send(JSON.stringify({
      type: 'world_state',
      wallet: store.getWallet(worldId, ANON_PLAYER),
      activeTask: store.getActiveTask(worldId, ANON_PLAYER),
      // 上次离开时玩家所在 tile（首次进世界 / 老档案无此字段 → 缺省，客户端按小神仙旁降生）
      playerPos: session.playerId ? store.getPlayer(session.playerId)?.position : undefined,
    }));
    return;
  }

  // 离开世界（前端正常退出显式发）：会话结束，flush 批量抽记忆并收尾 Visit。掉线未发则靠 socket.close 兜底。
  if (msg.type === 'leave_world') {
    session.creation = null; // 离开世界：丢弃未完成的造角色会话
    await endSessionVisit(session, adapters, store, Date.now());
    return;
  }

  // 委托完成事件（客户端确定性判定后上报）：匹配进行中委托则盖 1 章（满 3 升 1 花）+ 清任务
  if (msg.type === 'task_event') {
    const worldId = msg.worldId ?? '';
    const done = completeTaskOnEvent(worldId, {
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
      await createCharacterAsync(socket, msg.worldId ?? '', msg.intentText ?? '', adapters, store, undefined, session.clientTts);
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
      const childInput = (optId ? (findOption(optId)?.label ?? optId) : (msg.spokenText ?? '')).trim();
      if (!childInput) {
        socket.send(JSON.stringify({ type: 'voice_failed', reason: '造角色答复为空' }));
        return;
      }
      await advanceCreation(socket, session, msg.worldId ?? '', msg.characterId ?? '', childInput, adapters, store);
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

  if (msg.type === 'voice_input') {
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    try {
      const audioBytes = Uint8Array.from(Buffer.from(msg.audio ?? '', 'base64'));
      const transcript = (await adapters.asr.transcribe({ bytes: audioBytes, mime: msg.format ?? 'audio/wav' })).trim();
      // 造角色引导会话进行中：这句话当造角色答复，不走 routeIntent。
      if (session.creation?.active) {
        await advanceCreation(socket, session, msg.worldId ?? '', msg.characterId ?? '', transcript, adapters, store);
        return;
      }
      const response = await respondToTranscript(msg.worldId ?? '', msg.characterId ?? '', session.playerId, transcript, adapters, store, undefined, session.clientTts);
      // 造角色入口：开引导会话，不发普通回应。
      if (response.characterRequest) {
        await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.characterRequest, adapters, store, response.replyText);
        return;
      }
      socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, msg.worldId ?? '', response.propRequest, adapters, store, session.clientTts);
      }
      // 对话增量记进当前 Visit；会话结束（leave_world/close）批量抽记忆，省去每轮一次 LLM。
      recordVisitTurn(session, msg.worldId ?? '', session.playerId, msg.characterId ?? '', response.transcript, response.replyText, adapters, store);
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      gate.release();
    }
    return;
  }

  // ── 端侧 ASR：客户端（Android 插件）本地识别完成，直送转写文本，跳过服务端 ASR ──
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
      // 造角色引导会话进行中：这句话当造角色答复，不走 routeIntent。
      if (session.creation?.active) {
        await advanceCreation(socket, session, msg.worldId ?? '', msg.characterId ?? '', transcript, adapters, store);
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
      );
      // 造角色入口：respondToTranscript 识别到 create_character 意图但没出声，这里开引导会话，不发普通回应。
      if (response.characterRequest) {
        await openCreationSession(socket, session, msg.worldId ?? '', msg.characterId ?? '', response.characterRequest, adapters, store, response.replyText);
        return;
      }
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, msg.worldId ?? '', response.propRequest, adapters, store, session.clientTts);
      }
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

  // ── 边说边识别：分片随到随发讯飞，voice_end 时识别已基本完成（见 asr-live-stream 计划）──
  if (msg.type === 'voice_start') {
    if (session.gate) { session.gate.release(); session.gate = null; } // 上一会话没正常收尾，先释放
    const gate = limiter.tryAcquire(connKey, Date.now());
    if (!gate.ok) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: gate.reason }));
      return;
    }
    session.active = true;
    session.worldId = msg.worldId ?? '';
    session.characterId = msg.characterId ?? '';
    session.asr = adapters.asr.openStream(); // 立即开讯飞流，分片随到随发
    session.gate = gate;
    return;
  }

  if (msg.type === 'voice_chunk') {
    if (session.active && session.asr && msg.audio) session.asr.feed(Buffer.from(msg.audio, 'base64'));
    return; // 分片实时喂讯飞，不回包
  }

  // 误触/中途放弃（按住说话 <0.4s 松手）：丢弃识别流（finish 让讯飞关 WS/sherpa 释放，
  // 转写弃用），释放 gate，不回任何包——客户端取消后不该看到任何反馈。
  if (msg.type === 'voice_cancel') {
    if (session.asr) void session.asr.finish().catch(() => {});
    session.active = false;
    session.asr = null;
    if (session.gate) { session.gate.release(); session.gate = null; }
    return;
  }

  if (msg.type === 'voice_end') {
    if (!session.active || !session.asr) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: '没有进行中的录音会话' }));
      return;
    }
    const { worldId, characterId, playerId, asr } = session;
    session.active = false;
    session.asr = null;
    try {
      const transcript = await asr.finish(); // 识别尾巴：流式期间已基本识完
      // 造角色引导会话进行中：这句话当造角色答复，不走 routeIntent。
      if (session.creation?.active) {
        await advanceCreation(socket, session, worldId, characterId, transcript, adapters, store);
        return;
      }
      const ttsHooks = {
        onResponse: (r: VoiceResponse) => socket.send(JSON.stringify({ type: 'character_response', ...r })),
        onChunk: (pcm: Uint8Array) => socket.send(JSON.stringify({ type: 'tts_chunk', audio: Buffer.from(pcm).toString('base64') })),
        onEnd: (assetHash: string) => socket.send(JSON.stringify({ type: 'tts_end', ttsAsset: assetHash })),
      };
      const response = await respondToTranscript(worldId, characterId, playerId, transcript, adapters, store, ttsHooks, session.clientTts);
      // 造角色入口：开引导会话，不发普通回应。
      if (response.characterRequest) {
        await openCreationSession(socket, session, worldId, characterId, response.characterRequest, adapters, store, response.replyText);
        return;
      }
      if (!response.ttsStreaming) socket.send(JSON.stringify({ type: 'character_response', ...response }));
      if (response.propRequest) {
        void createPropAsync(socket, worldId, response.propRequest, adapters, store, session.clientTts);
      }
      recordVisitTurn(session, worldId, playerId, characterId, response.transcript, response.replyText, adapters, store);
    } catch (err) {
      socket.send(JSON.stringify({ type: 'voice_failed', reason: String(err) }));
    } finally {
      if (session.gate) { session.gate.release(); session.gate = null; }
    }
    return;
  }

  // 语音生成物件的落位回报：客户端就近找到空位后上报 tile，重载世界按此恢复
  if (msg.type === 'prop_place') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.setPropTile(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not found' }));
    }
    return;
  }

  // 物品摆放/背包（tile 占地校验在客户端 OccupancyMap，服务端只管状态机+持久化）：
  // prop_store 收纳 / prop_take 摆出 / prop_move 挪位。成功无回包（与 prop_place 一致），非法转换回 error。
  if (msg.type === 'prop_store') {
    if (!store.storeProp(msg.worldId ?? '', msg.propId ?? '')) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not placed' }));
    }
    return;
  }
  if (msg.type === 'prop_take') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.takeProp(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not bagged' }));
    }
    return;
  }
  if (msg.type === 'prop_move') {
    const tile: [number, number] = [Math.trunc(Number(msg.tileX ?? -1)), Math.trunc(Number(msg.tileY ?? -1))];
    if (!store.movePropTile(msg.worldId ?? '', msg.propId ?? '', tile)) {
      socket.send(JSON.stringify({ type: 'error', error: 'prop not placed' }));
    }
    return;
  }

  // 角色/玩家坐标回报：空间权威在客户端，服务端只记最后位置供下次进世界读回。
  // 静止时客户端不发；每拍只带 tile 变化过的角色。越界 tile 静默丢弃（单个坏条目不连坐整批）。
  if (msg.type === 'positions_report') {
    const worldId = msg.worldId ?? '';
    const entries = Array.isArray(msg.chars) ? msg.chars : [];
    let applied = 0;
    for (const raw of entries) {
      if (typeof raw !== 'object' || raw === null) continue;
      const e = raw as { id?: unknown; tileX?: unknown; tileY?: unknown };
      if (typeof e.id !== 'string' || !e.id) continue;
      const tile: TilePos = { tileX: Number(e.tileX), tileY: Number(e.tileY) };
      if (!isValidTile(tile)) continue;
      if (store.setCharacterTile(worldId, e.id, tile)) applied++;
    }
    // 玩家自己的位置（Player 表；档案未建时静默跳过——首次进世界还没上报 profile）。
    if (typeof msg.player === 'object' && msg.player !== null && session.playerId) {
      const p = msg.player as { tileX?: unknown; tileY?: unknown };
      const tile: TilePos = { tileX: Number(p.tileX), tileY: Number(p.tileY) };
      if (isValidTile(tile)) store.setPlayerTile(session.playerId, tile);
    }
    // 成功无回包（与 prop_place 一致）；整批一个角色都没落地才回 error，便于客户端察觉世界/角色 id 错配。
    if (entries.length > 0 && applied === 0) {
      socket.send(JSON.stringify({ type: 'error', error: 'no character position applied' }));
    }
    return;
  }

  socket.send(JSON.stringify({ type: 'error', error: `unknown type: ${msg.type}` }));
}
