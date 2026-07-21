// 《白雪公主》第 0 幕 · 数七个小矮人（第一季册 3 · 数学「数到 7」，docs/s1-snow-white-design.md §6）。
// 互动演出章：白雪走进森林的旁白 + 数数游戏连着跑；数满两关 → stage.end 赢 → 服务端 emitPerformReward
// 按 performReward 发盖章（§5）。全程【纯 tap】：观演态玩家不能走动 avatar、唯 tap 例外
// （world.gd:3117 吞输入 / 3126 把点中的演员送 on_local_tap→tap 订阅）。
// 零挫败：无倒计时、重复点只温柔提醒不扣分；中途走开 → 舞台 abort 回幕首，重触发从头玩、不重复发奖。
// 台词全为字面量（.say/.narrate），与 assets/voice/story_snow_white/lines.json 一一对应预烧。

const [snow, doc, happy, sleepy, bashful, sneezy, grumpy, dizzy] =
  cast('白雪公主', '博士', '乐乐', '困困', '羞羞', '喷喷', '气气', '迷糊');

// 点点报数（只念 1..7，全字面量以便预烧）。
async function countUpTo(n: number): Promise<void> {
  if (n === 1) return stage.narrate('一个！');
  if (n === 2) return stage.narrate('两个！');
  if (n === 3) return stage.narrate('三个！');
  if (n === 4) return stage.narrate('四个！');
  if (n === 5) return stage.narrate('五个！');
  if (n === 6) return stage.narrate('六个！');
  return stage.narrate('七个！');
}

// 一关：给每个矮人挂 tap。点没数过的 → 反应(字面量 say) + 计数 + 点点报数；点重复的 → 温柔提醒。
// 数满 entries.length → 退订全部 tap、resolve。sayIt 里的 .say 是字面量，随源码被预烧覆盖。
function runTapPhase(label: string, entries: Array<[Actor, () => Promise<void>]>): Promise<void> {
  const board = stage.hud.score(label);
  const seen = new Set<string>();
  return new Promise<void>((resolve) => {
    const unsubs = entries.map(([d, sayIt]) =>
      stage.on('tap', d, async () => {
        if (seen.has(d.id)) {
          await stage.narrate('这个我们数过啦，点点别的小矮人吧～');
          return;
        }
        seen.add(d.id);
        board.add(1);
        await sayIt();
        await countUpTo(seen.size);
        if (seen.size === entries.length) {
          for (const u of unsubs) u();
          resolve();
        }
      }),
    );
  });
}

// ── 开场：白雪走进森林、来到七矮人小屋（去惊吓，无王后/猎人，与去凶化的狼同口径）──
stage.camera.overview();
stage.banner('白雪公主 · 七个小矮人');
await stage.narrate('白雪公主想去森林里看看，一个人走进了大树林。');
await stage.narrate('走呀走，她来到一座小小的木头房子前，屋里住着七个小矮人。');
stage.camera.focus(snow);
await snow.say('这里好乱呀，我来帮小矮人们把家收拾好！', 'twirl');
await stage.narrate('白雪想帮忙，可要先数清楚——一共有几个小矮人呢？');

// ── 第一关：点一点，数矮人 ──
await stage.narrate('小朋友，我们一个一个点点看，数数一共有几个小矮人，好不好？');
await runTapPhase('数矮人', [
  [doc, () => doc.say('我是博士，数数交给我最在行！', 'nod')],
  [happy, () => happy.say('我是乐乐，嘻嘻嘻，你好呀！', 'jump')],
  [sleepy, () => sleepy.say('我是困困……哈啊……好困哦。', 'stretch')],
  [bashful, () => bashful.say('我、我是羞羞……你别盯着我看啦。', 'peek')],
  [sneezy, () => sneezy.say('我是喷喷，阿……阿嚏！', 'shiver')],
  [grumpy, () => grumpy.say('哼，我是气气，数快点啦！', 'puff')],
  [dizzy, () => dizzy.say('我是迷糊，咦，你点的是我吗？', 'wiggle')],
]);
await stage.narrate('一共有七个小矮人，全部数清楚啦！');

// ── 第二关：一人一个碗（一一对应，再点一次＝盛一碗）──
await stage.narrate('小矮人们饿啦，我们给每人盛一碗饭吧，一个小矮人一个碗，一个都不能少哦。');
await runTapPhase('盛碗', [
  [doc, () => doc.say('谢谢你的碗，我要装满浆果！', 'nod')],
  [happy, () => happy.say('有饭吃啦，嘻嘻，谢谢你！', 'jump')],
  [sleepy, () => sleepy.say('嗯……谢谢……我吃一口就睡……', 'stretch')],
  [bashful, () => bashful.say('谢、谢谢你……我小声说谢谢。', 'peek')],
  [sneezy, () => sneezy.say('谢谢你，阿嚏——哎呀吹到饭啦！', 'shiver')],
  [grumpy, () => grumpy.say('哼，谢谢……其实我很开心啦。', 'puff')],
  [dizzy, () => dizzy.say('咦，这碗是给我的吗？谢谢你！', 'wiggle')],
]);
await stage.narrate('七个碗都盛好啦，七个小矮人一人一碗，正正好！');

// ── 收场：白雪道谢 → stage.end 赢（触发 performReward 盖章）──
stage.camera.focus(snow);
await snow.say('谢谢你帮我数清楚小矮人，还给大家盛了饭，你真棒！', 'bounce');
stage.camera.reset();
stage.end({ praise: '数得真棒，七个小矮人一个都不少！' });
