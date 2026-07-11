/**
 * 端到端验证：小朋友点名要某个 IP 角色 → LLM 必须把它翻译成纯外观描述（visualDescription 里无 IP 名）。
 * 只跑 LLM 那一步（文本模型不受 OpenRouter 区域限制）；生图那一步在首尔机器上跑（见 scratchpad）。
 *
 *   OPENROUTER_API_KEY=... npx tsx scripts/verify-ip-to-appearance.ts
 */
import { OpenRouterClient } from '../src/adapters/openrouter_client.ts';
import { OpenRouterLLMAdapter } from '../src/adapters/openrouter_llm.ts';
import { loadConfig } from '../src/config.ts';

const cfg = loadConfig();
const llm = new OpenRouterLLMAdapter(new OpenRouterClient(cfg.openrouterApiKey), cfg.llmModel);

// 小朋友的原话（造角色 description 就是这种口语）
const WISHES = [
  '我要一个皮卡丘',
  '我想要艾莎公主，就是冰雪奇缘那个',
  '给我变一个海绵宝宝',
  '我要一只会飞的紫色小恐龙',   // 对照：本来就不是 IP，不该被改坏
];

// visualDescription 里出现这些词就算泄漏（大小写不敏感）
const IP_WORDS = [
  'pikachu', 'pokemon', 'pokémon', 'elsa', 'frozen', 'disney', 'spongebob', 'sponge bob',
  'nintendo', 'mario', 'squarepants', 'anna', 'olaf',
];

let leaked = 0;
for (const wish of WISHES) {
  const spec = await llm.designCharacter(wish);
  const vd = spec.visualDescription;
  const hits = IP_WORDS.filter((w) => vd.toLowerCase().includes(w));
  const ok = hits.length === 0;
  if (!ok) leaked++;
  console.log(`\n${ok ? '✅' : '❌ IP 名泄漏: ' + hits.join(',')}  「${wish}」`);
  console.log(`   name: ${spec.name}`);
  console.log(`   visualDescription: ${vd}`);
}

console.log(`\n${leaked === 0 ? '✅ 全部通过' : `❌ ${leaked} 条泄漏了 IP 名`}：${WISHES.length} 条愿望，visualDescription 中 IP 名出现 ${leaked} 次`);
process.exit(leaked === 0 ? 0 : 1);
