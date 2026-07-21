// 《小红帽》第一幕 · 送点心（第一季册 2，docs/season-1-outline.md §4 / s1-merged-scene-layout.md）。
// 手作剧本：narrate/say/do/banner/camera，不用 moveTo（走位是互动幕的 guide_to 引路，孩子自己走）。
// 台词与 assets/voice/story_hood/lines.json 一一对应（预烧 WAV，客户端按文本命中播包）。
// 尾随互动：task:visit 外婆家——点点飞前面引路，孩子把点心送到外婆家（poi_grandma）。

const [redHood] = cast('小红帽');

stage.camera.overview();
stage.banner('小红帽 · 送点心');
await stage.narrate('小红帽的外婆生病啦，妈妈装了一篮子香喷喷的点心。');

stage.camera.focus(redHood);
await redHood.say('我要把点心送给外婆，让她快点好起来！', 'puff');
await redHood.do('twirl');

await stage.narrate('妈妈说，去外婆家要走那条穿过树林的小路，一路上别贪玩，早点到哦。');
await redHood.say('好哒！我这就出发，走小路去外婆家！', 'wave');

await stage.narrate('小路弯弯，穿过一片树林。点点会飞在前面给你带路，我们一起把点心送到外婆家吧！');
stage.camera.reset();
stage.end({ praise: '出发去外婆家啦！' });
