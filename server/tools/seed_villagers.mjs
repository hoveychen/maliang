// 向 default 世界生成一批初始村民（真实后端：Kimi 造 spec + Gemini 生图 + 抠图）。
// 用法: SEED_BASE=https://maliang-api.muveeai.com node tools/seed_villagers.mjs
// 默认本地 http://127.0.0.1:8080。顺序生成（避开全局并发限流）。

const BASE = process.env.SEED_BASE || 'http://127.0.0.1:8080';
const WS = BASE.replace(/^http/, 'ws') + '/ws';

const INTENTS = [
  '一只爱跳舞、穿蓬蓬裙的小兔',
  '一只爱睡觉、戴睡帽的小猫',
  '一只憨厚、背着背篓的小熊',
  '一只机灵、围红围巾的小狐狸',
  '一只温柔、戴花环的小鹿',
  '一只爱唱歌、叼着乐谱的小鸟',
];

function createOne(intent) {
  return new Promise((resolve) => {
    const ws = new WebSocket(WS);
    const t = Date.now();
    const timer = setTimeout(() => {
      try { ws.close(); } catch {}
      resolve({ ok: false, reason: 'timeout' });
    }, 120000);
    ws.onopen = () =>
      ws.send(JSON.stringify({ type: 'create_character_request', worldId: 'default', intentText: intent, byFairy: true }));
    ws.onmessage = (m) => {
      const d = JSON.parse(m.data);
      if (d.type === 'gen_complete') {
        clearTimeout(timer); ws.close();
        resolve({ ok: true, name: d.character?.name, ms: Date.now() - t });
      } else if (d.type === 'gen_failed') {
        clearTimeout(timer); ws.close();
        resolve({ ok: false, reason: d.reason });
      }
    };
    ws.onerror = () => { clearTimeout(timer); resolve({ ok: false, reason: 'ws error' }); };
  });
}

console.error(`seeding default world @ ${BASE}`);
await fetch(BASE + '/worlds/default').catch(() => {}); // 触发自动创建 default 世界
let ok = 0;
for (const intent of INTENTS) {
  const r = await createOne(intent);
  if (r.ok) { ok++; console.error(`  ✓ ${r.name} (${(r.ms / 1000).toFixed(1)}s)`); }
  else console.error(`  ✗ ${intent} → ${r.reason}`);
}
const w = await (await fetch(BASE + '/worlds/default')).json();
console.error(`done: ${ok}/${INTENTS.length} 村民生成；default 世界现有角色 ${w.characters?.length ?? '?'} 个`);
