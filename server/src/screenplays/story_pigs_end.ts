// 《三只小猪》尾声 · 谢幕（M2 章回剧情）。砖房盖好（build 互动的回报）：狼吹不倒、
// 晕头转向滑稽跑掉（4 岁向：鼓腮帮滑稽戏，不吓人），三只小猪道谢——演完整册完结、入住村子。
// 无互动无盖章（StoryChapter.interaction 缺省）。台词与 lines.json 一一对应。

const [big, mid, small, wolf] = cast('猪大哥', '猪二哥', '猪小弟', '大灰狼');

stage.camera.overview();
stage.banner('三只小猪 · 尾声 最结实的家');
await stage.narrate('砖头房子盖好啦！大灰狼气冲冲地跑了过来。');

stage.camera.focus(wolf);
await wolf.say('我吹我吹，我吹吹吹！', 'puff');
await wolf.do('puff');
await wolf.do('puff');
await stage.narrate('砖房子稳稳当当，一动也不动。');
await wolf.do('faceplant');
await wolf.say('哎哟哟，头都吹晕啦……我再也不吹房子啦！', 'shiver');
await stage.narrate('大灰狼揉着脑袋，灰溜溜地跑远啦，再也没有回来。');

stage.camera.dialog(big, small);
await big.say('谢谢你，小朋友！这是我们最结实的家！', 'wave');
await mid.say('太棒啦！以后我们就住在村子里啦！', 'jump');
await small.say('我们做好朋友吧，天天一起玩！', 'twirl');
await stage.narrate('从此，三只小猪就在村子里住了下来，和大家做了邻居。');

stage.camera.reset();
stage.end({ praise: '故事演完啦！三只小猪住进村子里啦！' });
