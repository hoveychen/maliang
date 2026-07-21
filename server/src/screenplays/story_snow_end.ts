// 《白雪公主》尾声 · 讲给小矮人听（第一季册 3，复述收尾 + 整册完结入住）。
// 无互动无盖章：演完整册完结，白雪与七个小矮人入住这片森林（story_seed.settleStoryResidency）。
// 语文挂点：点点请孩子把白雪和七矮人的故事讲一遍（听 → 复述，stage.prompt，零挫败不打分）。
// 台词与 assets/voice/story_snow_white/lines.json 一一对应。演员只 cast 用到的两个（白雪+博士代表七矮人）。

const [snow, doc] = cast('白雪公主', '博士');

stage.camera.overview();
stage.banner('白雪公主 · 森林里的家');
await stage.narrate('从此白雪公主和七个小矮人成了好朋友，一起住在森林里的小木屋。');

stage.camera.dialog(snow, doc);
await doc.say('多亏你帮忙，我们的家又整齐、大家又吃得饱饱的！', 'nod');
await snow.say('小朋友，你陪我们过了好开心的一天！', 'bounce');

await stage.narrate('点点悄悄飞到你耳边，轻轻地问。');
await stage.narrate('小朋友，你愿意把白雪和七个小矮人的故事，讲给他们听一听吗？');
await stage.prompt(snow, '把刚才的故事讲给小矮人听吧（想说什么都可以）');

await doc.say('讲得真好听，谢谢你！', 'jump');
await stage.narrate('从今天起，白雪和七个小矮人就住在这片森林里啦，随时欢迎你来玩。');
stage.camera.reset();
stage.end({ praise: '整本故事讲完啦！' });
