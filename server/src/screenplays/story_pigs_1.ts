// 《三只小猪》第一幕 · 草房子（M2 章回剧情，docs/m2-story-director-design.md §5）。
// 手作剧本：narrate/say/do/banner/camera，不用 moveTo（村庄 POI 因世界而异，走位留给站位）。
// 台词与 assets/voice/story_three_pigs/lines.json 一一对应（预烧 WAV，客户端按文本命中播包）。

const [mid, small, wolf] = cast('猪二哥', '猪小弟', '大灰狼');

stage.camera.overview();
stage.banner('三只小猪 · 第一幕 草房子');
await stage.narrate('从前，有三只小猪，他们要各自盖一座小房子。');

stage.camera.focus(small);
await small.say('我用软软的稻草，一下子就盖好啦！', 'stretch');
await small.do('twirl');

await stage.narrate('猪小弟的草房子刚盖好，大灰狼就晃晃悠悠地来了。');
stage.camera.focus(wolf);
await wolf.say('小猪小猪，看我吹一口大大的气！', 'puff');
await wolf.do('puff');

await stage.narrate('呼——草房子一下子就被吹倒啦。');
await small.say('哎呀呀，我的草房子！', 'shiver');

stage.camera.dialog(small, mid);
await small.say('二哥二哥，快让我进去躲一躲！');
await mid.say('快进来快进来，我的木头房子可结实啦！', 'wave');

await stage.narrate('猪小弟躲进了猪二哥的木房子。大灰狼还会追来吗？');
stage.camera.reset();
stage.end({ praise: '第一幕演完啦！' });
