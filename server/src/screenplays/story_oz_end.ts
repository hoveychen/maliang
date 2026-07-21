// 《绿野仙踪》尾声 · 翡翠城（第一季册 5，docs/season-1-outline.md §4）。
// 无互动无盖章：演完整册完结，桃乐丝、稻草人、铁皮人三人都住进这条黄砖路（老板 2026-07-21 定：都入住）。
// 语文挂点：点点请孩子把桃乐丝的故事讲给大家听（听 → 复述，stage.prompt，零挫败不打分）。
// 英语纪律：桃乐丝冒一两句简单英文，点点中文翻译，不要求跟读。台词与 lines.json 一一对应（英文避撇号）。

const [dorothy, scarecrow, tinman] = cast('桃乐丝', '稻草人', '铁皮人');

stage.camera.overview();
stage.banner('绿野仙踪 · 翡翠城');
await stage.narrate('顺着黄砖路一直走，一座亮晶晶的绿色城堡出现在眼前——翡翠城到啦！');

stage.camera.dialog(dorothy, scarecrow);
await dorothy.say('We did it! Thank you, my friends!', 'twirl');
await stage.narrate('桃乐丝好开心。她说「我们做到啦！谢谢你们，我的朋友们」。');
await scarecrow.say('跟着你，我好像真的变聪明啦！', 'jump');
await tinman.say('我的心里暖乎乎的，这大概就是有一颗心的感觉吧。', 'nod');

await stage.narrate('点点悄悄飞到你的耳边，轻轻地问。');
await stage.narrate('小朋友，你愿意把桃乐丝一路交朋友、说英文的故事，讲给大家听一听吗？');
await stage.prompt(dorothy, '把刚才的故事讲给大家听吧（想说什么都可以）');

await dorothy.say('You are my best friend! Bye bye!', 'wave');
await stage.narrate('桃乐丝说「你是我最好的朋友，再见啦」。从今天起，桃乐丝、稻草人和铁皮人就住在这条黄砖路上，随时欢迎你来玩。');
stage.camera.reset();
stage.end({ praise: '整本故事讲完啦！' });
