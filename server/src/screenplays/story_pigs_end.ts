// 《三只小猪》尾声 · 大灰狼的新家（M2 章回剧情）。砖房盖好（build 互动的回报）：狼吹不倒、
// 晕头转向又饿又孤单，三只小猪不计前嫌分饭给它——狼感动改邪归正、道歉入伙，搬进村边自己的小窝，
// 从此大家做了邻居。演完整册完结、四位（三猪＋狼）一起入住。无互动无盖章（interaction 缺省）。
// 台词与 assets/voice/story_three_pigs/lines.json 一一对应（精确文本命中预烧 WAV，miss 回落 clientTts）。

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
await wolf.say('哎哟哟，头都吹晕啦……', 'shiver');
await stage.narrate('大灰狼一屁股坐在地上，肚子咕噜咕噜地叫，又饿又孤单。');
await wolf.do('curl_up');

// 大灰狼的新家 · 小猪分饭
stage.banner('三只小猪 · 尾声 大灰狼的新家');
stage.camera.dialog(small, wolf);
await small.say('大灰狼，你是不是肚子饿啦？', 'peek');
stage.camera.dialog(big, mid);
await big.say('我们刚做了热乎乎的饭，一起吃点吧。', 'wave');
await mid.say('对呀对呀，别一个人啦！', 'jump');
await stage.narrate('三只小猪端来香喷喷的饭菜，分给了大灰狼。');

stage.camera.focus(wolf);
await wolf.do('wiggle');
await wolf.say('对不起……我不该老想吹倒你们的房子，我只是……想有人陪我玩。', 'shiver');
await small.say('那你留下来嘛！我们做邻居，天天一起玩！', 'twirl');
await stage.narrate('大灰狼高兴得又蹦又跳，在村子边上给自己搭了一个暖暖的小窝。');
await wolf.do('bounce');
await wolf.do('spin');

stage.camera.overview();
await big.say('谢谢你，小朋友！这是我们最结实的家！', 'wave');
await wolf.say('也谢谢你，小朋友！以后来找我玩呀！', 'wave');
await stage.narrate('从此，三只小猪和大灰狼都在村子里住了下来，和大家做了好邻居。');

stage.camera.reset();
stage.end({ praise: '故事演完啦！三只小猪和大灰狼都住进村子里啦！' });
