// 《三只小猪》第三幕 · 盖砖房（M2 章回剧情）。狼逼近、砖房没盖完、向小朋友求助——
// 演出收场后进 build 互动（B1 积木拼「小房子」蓝图），「狼吹不倒」的回报放尾声。
// 台词与 assets/voice/story_three_pigs/lines.json 一一对应。

const [big, mid, small, wolf] = cast('猪大哥', '猪二哥', '猪小弟', '大灰狼');

stage.camera.overview();
stage.banner('三只小猪 · 第三幕 盖砖房');
await stage.narrate('三只小猪终于都到齐了，可是砖头房子还差好多砖呢。');

stage.camera.focus(big);
await big.say('大灰狼快追来啦，砖房子还没盖完！', 'shiver');
stage.camera.focus(wolf);
await wolf.say('嘿嘿嘿，我闻到小猪的味道啦——', 'peek');
await wolf.do('peek');

stage.camera.dialog(small, mid);
await small.say('怎么办呀，怎么办呀！', 'shiver');
await mid.say('对啦！请我们的小朋友来帮忙呀！', 'jump');

stage.camera.focus(big);
await big.say('小朋友，帮我们一起把砖房子拼起来，好不好？', 'bow_fold');
await stage.narrate('快帮小猪们把砖头房子盖好吧！');
stage.camera.reset();
stage.end({ praise: '快去帮小猪盖砖房吧！' });
