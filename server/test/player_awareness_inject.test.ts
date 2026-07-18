import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createMockAdapters } from '../src/adapters/mock.ts';
import { buildServer } from '../src/server.ts';
import { respondToTranscript } from '../src/voice.ts';
import { WorldStore } from '../src/persistence.ts';
import { appearanceNote } from '../src/avatar_options.ts';
import type { Character, IntentContext, ItemDef, PlayerOnboardingProfile } from '../src/types.ts';

// 对话玩家感知（docs/... 信息模型）：
//  · 外观 + 身上贴纸（appearanceNote）—— 当面可见，点点/村民都注入。
//  · 名字/喜好摘要（childProfile）—— 信息不对称，只点点注入；村民不先天知道，靠聊积累。

function profile(overrides: Partial<PlayerOnboardingProfile> = {}): PlayerOnboardingProfile {
  return {
    playerId: 'p1', name: '朵朵', nickname: '朵朵',
    attrs: { gender: '小女生', color: '粉色', motifs: ['小恐龙', '星星'], extras: [] },
    visualDescription: '一个扎粉色马尾、穿星星裙的小女孩', refineNotes: [], spriteAsset: 'h', createdAt: '',
    ...overrides,
  };
}

function stickerItem(worldId: string, id: string, name: string): ItemDef {
  return {
    id, worldId, name, renderRef: `sticker:${name}`,
    footprintW: 1, footprintH: 1, blocking: false, pathOk: true, wander: 0, mount: 'edge',
  };
}

test('appearanceNote：外观+贴纸拼一句；缺哪块省哪块；全空返回 undefined', () => {
  assert.equal(
    appearanceNote('扎粉色马尾的小女孩', ['星星贴纸', '爱心贴纸']),
    '长得是「扎粉色马尾的小女孩」，身上贴着星星贴纸、爱心贴纸',
  );
  assert.equal(appearanceNote('扎粉色马尾的小女孩', []), '长得是「扎粉色马尾的小女孩」', '只外观');
  assert.equal(appearanceNote(undefined, ['星星贴纸']), '身上贴着星星贴纸', '只贴纸');
  assert.equal(appearanceNote('', []), undefined, '全空不注入');
  assert.equal(appearanceNote('   ', ['  ']), undefined, '纯空白也算空');
});

test('respondToTranscript：点点拿到 childProfile+appearanceNote，村民只拿到 appearanceNote', async () => {
  const store = new WorldStore();
  const adapters = createMockAdapters();
  const app = await buildServer({ adapters, store });
  try {
    await app.inject({ method: 'GET', url: '/worlds/default' }); // 种默认世界（含点点）
    const fairy = store.listCharacters('default').find((c) => c.isFairy)!;
    // 造一个村民：克隆点点、翻转 isFairy、换 id（种子世界只有点点，没有村民可用）。
    const villager: Character = { ...fairy, id: 'villager-1', name: '小蓝', isFairy: false };
    store.addCharacter(villager);

    // 玩家 p1：有 onboarding 档案（含外观 visualDescription）+ 身上贴一张「星星贴纸」。
    store.saveOnboardingProfile(profile());
    store.upsertItem(stickerItem('default', 'test_sticker_star', '星星贴纸'));
    store.upsertPlayer({
      id: 'p1', name: '朵朵', nickname: '朵朵', gender: 'girl', color: '粉色',
      spriteAsset: 'h', createdAt: '', attachments: [{ slot: 'headTop', itemId: 'test_sticker_star' }],
    });

    const captured: IntentContext[] = [];
    const origRoute = adapters.llm.routeIntent.bind(adapters.llm);
    adapters.llm.routeIntent = async (transcript, ctx) => {
      captured.push(ctx);
      return origRoute(transcript, ctx);
    };

    // 点点：喜好摘要 + 外观都在。
    await respondToTranscript('default', fairy.id, 'p1', '你好呀', adapters, store);
    assert.equal(captured.length, 1, 'routeIntent 被调用');
    assert.ok(captured[0]!.childProfile?.includes('小恐龙'), '点点拿到喜好摘要');
    assert.ok(captured[0]!.appearanceNote?.includes('粉色马尾'), '点点拿到外观');
    assert.ok(captured[0]!.appearanceNote?.includes('星星贴纸'), '点点看到身上的贴纸');

    // 村民：外观在，喜好摘要不给（信息不对称）。
    await respondToTranscript('default', villager.id, 'p1', '你好呀', adapters, store);
    assert.equal(captured[1]!.childProfile, undefined, '村民不先天知道名字/喜好');
    assert.ok(captured[1]!.appearanceNote?.includes('粉色马尾'), '村民也当面看得到外观');
    assert.ok(captured[1]!.appearanceNote?.includes('星星贴纸'), '村民也看得到身上的贴纸');
  } finally {
    await app.close();
  }
});
