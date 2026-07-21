// 《龟兔赛跑》第一幕 · 村口约赛跑（第一季册 4，docs/season-1-outline.md §4）。
// 管理种子（先做哪个 / 用什么节奏）。手作剧本：narrate/say/do/banner/camera，不用 moveTo
// （走位是互动幕的 guide_to 引路，孩子自己走去跑道）。台词与 assets/voice/story_tortoise_hare/
// lines.json 一一对应（预烧 WAV，客户端按文本命中播包）。
// 尾随互动：task:visit 跑道——点点飞前面引路，孩子走到东缘跑道给龟兔加油（poi_race）。

const [tortoise, hare] = cast('乌龟', '兔子');

stage.camera.overview();
stage.banner('龟兔赛跑 · 村口约赛跑');
await stage.narrate('村口热闹起来啦！乌龟和兔子要比一比，看谁先跑到终点。');

stage.camera.focus(hare);
await hare.say('哼，就凭乌龟那小短腿？我兔子一眨眼就冲到终点啦！', 'puff');
await hare.do('bounce');

stage.camera.focus(tortoise);
await tortoise.say('我跑得慢，可是我会一步一步，稳稳地走到终点。', 'nod');

await stage.narrate('他们约好在东边的跑道上比赛。走，我们一起去跑道给他们加油吧！');
stage.camera.reset();
stage.end({ praise: '去跑道给他们加油啦！' });
