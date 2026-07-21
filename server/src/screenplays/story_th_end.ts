// 《龟兔赛跑》尾声 · 跑道上的比赛（第一季册 4，docs/season-1-outline.md §4）。
// 无互动无盖章：演完整册完结，乌龟与兔子入住村子。这一幕是全册高潮——真正的赛跑演出。
//
// 二选一（管理种子·零挫败）：点点问「给谁加油」，孩子点一点乌龟或兔子。老板 2026-07-21 拍板
// 「殊途同归·都温暖」——无论点谁（或不点），结局都是兔子冲太快睡过头、乌龟稳步先到，
// 最后大家一起笑着做朋友；没有「选错」，管理种子靠「看见稳步的好」隐性传递（CLAUDE.md 铁律#1）。
// 没点也不卡：sleep(15) 兜底成 'none' 分支，点点一句「一起给他们加油」照常往下演。
//
// 走位：不用 moveTo——像《小红帽》尾声（小红帽在村里、外婆在树林边，camera.dialog 照样对戏），
// 这是一段导演式过场，龟兔的赛跑动作用 do 动画 + 运镜表达，孩子已由互动幕 visit 走到了跑道。
// 语文挂点：结尾点点请孩子把故事讲给龟兔听（听 → 复述，stage.prompt，零挫败不打分）。
// 台词与 assets/voice/story_tortoise_hare/lines.json 一一对应。

const [tortoise, hare] = cast('乌龟', '兔子');

stage.camera.overview();
stage.banner('龟兔赛跑 · 跑道上');
await stage.narrate('你和点点一起来到了跑道边，乌龟和兔子已经站在起跑线上啦。');

// 二选一：给谁加油？点一点它！（tap，点谁都对；没点则 sleep 兜底不卡）
await stage.narrate('小朋友，你想给谁加油呢？点一点乌龟，或者点一点兔子吧！');
const pick = await Promise.race([
  stage.once('tap', tortoise).then(() => 'tortoise'),
  stage.once('tap', hare).then(() => 'hare'),
  stage.sleep(15).then(() => 'none'),
]);

if (pick === 'hare') {
  stage.camera.focus(hare);
  await hare.say('好嘞！有你给我加油，看我一下子就冲到终点！', 'puff');
} else if (pick === 'tortoise') {
  stage.camera.focus(tortoise);
  await tortoise.say('谢谢你给我加油，我会一步一步稳稳地走。', 'nod');
} else {
  await stage.narrate('那我们就一起给他们俩加油吧——加油！加油！');
}

// 殊途同归：兔子冲太快睡过头、乌龟稳步先到；点谁都这么演，都温暖。
stage.camera.overview();
await stage.narrate('比赛开始啦！兔子嗖地冲了出去，一下子就跑得老远。');
await hare.do('bounce');
await hare.say('乌龟还在后面慢吞吞呢，我先在树荫下睡一小会儿～', 'stretch');
await hare.do('lie_down');

await stage.narrate('乌龟呢，一步，一步，稳稳地往前走，一点也不着急。');
await tortoise.do('bounce');
await tortoise.say('慢慢来，一步一步，也能走到终点。', 'nod');

await stage.narrate('等兔子睡醒，揉揉眼睛一看——乌龟已经稳稳地到终点啦！');
stage.camera.dialog(tortoise, hare);
await hare.say('哎呀我睡过头啦！乌龟你真厉害，一步一步竟然先到了！', 'shiver');
await tortoise.say('没关系呀，一起跑得开心最重要，下次我们再一起玩！', 'wave');
await hare.do('jump');

// 语文收尾：复述（零挫败不打分）
await stage.narrate('点点悄悄飞到你的耳边，轻轻地问。');
await stage.narrate('小朋友，你愿意把龟兔赛跑的故事，讲给乌龟和兔子听一听吗？');
await stage.prompt(tortoise, '把刚才的故事讲给乌龟和兔子听吧（想说什么都可以）');

await tortoise.say('讲得真好听！谢谢你今天来给我们加油。', 'twirl');
await stage.narrate('从今天起，乌龟和兔子就住在村子里啦，随时欢迎你来一起玩、一起跑。');
stage.camera.reset();
stage.end({ praise: '整本故事讲完啦！' });
