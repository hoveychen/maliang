// 《小红帽》尾声 · 讲给外婆听（第一季册 2，docs/season-1-outline.md §4）。
// 无互动无盖章：演完整册完结，小红帽与外婆入住这片树林边。
// 语文挂点：到外婆家，点点请孩子把小红帽的故事讲给外婆听（听 → 复述，stage.prompt，零挫败不打分）。
// 台词与 assets/voice/story_hood/lines.json 一一对应。

const [redHood, granny] = cast('小红帽', '外婆');

stage.camera.overview();
stage.banner('小红帽 · 到外婆家啦');
await stage.narrate('走过弯弯的小路，你和小红帽一起来到了外婆家。');

stage.camera.dialog(redHood, granny);
await redHood.say('外婆外婆，我来给你送点心啦！', 'bounce');
await granny.say('哎哟，我的乖宝贝，还有小朋友一起来，外婆真高兴！', 'wave');
await granny.say('有你们来看外婆，外婆的病一下子就好了一半啦。', 'nod');

await stage.narrate('点点悄悄飞到你的耳边，轻轻地问。');
await stage.narrate('小朋友，你愿意把小红帽送点心的故事，讲给外婆听一听吗？');
await stage.prompt(redHood, '把刚才的故事讲给外婆听吧（想说什么都可以）');

await granny.say('讲得真好听，谢谢你陪小红帽走这一趟。', 'twirl');
await stage.narrate('从今天起，小红帽和外婆就住在这片树林边啦，随时欢迎你来玩。');
stage.camera.reset();
stage.end({ praise: '整本故事讲完啦！' });
