// 《三只小猪》第二幕 · 木房子（M2 章回剧情）。狼吹倒木房，两只猪跑散——
// 猪二哥逃到大哥家，猪小弟吓得躲了起来，引出「带话给猪小弟」的互动。
// 台词与 assets/voice/story_three_pigs/lines.json 一一对应。

const [big, mid, small, wolf] = cast('猪大哥', '猪二哥', '猪小弟', '大灰狼');

stage.camera.overview();
stage.banner('三只小猪 · 第二幕 木房子');
await stage.narrate('大灰狼摇摇摆摆，跟着追到了木房子前面。');

stage.camera.focus(wolf);
await wolf.say('木头房子？我也吹得倒！呼——', 'puff');
await wolf.do('puff');
await wolf.do('puff');

await stage.narrate('呼——呼——木房子摇摇晃晃，也倒下啦。');
stage.camera.dialog(mid, small);
await mid.say('哎呀，我的木房子也倒啦！', 'shiver');
await small.say('快跑快跑，去大哥家！', 'shiver');

await stage.narrate('两只小猪撒腿就跑。猪二哥跑到了大哥家，咦，猪小弟呢？');
stage.camera.dialog(big, mid);
await big.say('猪小弟怎么没跟来呀？', 'nod');
await mid.say('他吓坏了，躲到别处去啦！');
await big.say('得快点告诉他，到我的砖房这儿来！', 'wave');

await stage.narrate('猪小弟还躲着呢，谁去把大哥的话带给他呀？');
stage.camera.reset();
stage.end({ praise: '第二幕演完啦！' });
