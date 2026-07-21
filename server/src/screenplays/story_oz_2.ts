// 《绿野仙踪》第二幕 · 谢谢铁皮人（第一季册 5，docs/season-1-outline.md §4）。
// 稻草人入队（想要聪明脑袋）→ 遇到生锈的铁皮人（想要一颗心）帮指路。
// 尾随互动：task:deliver——帮桃乐丝把 'Thank you!' 带给铁皮人。台词与 lines.json 一一对应（英文避撇号）。

const [dorothy, scarecrow, tinman] = cast('桃乐丝', '稻草人', '铁皮人');

stage.camera.overview();
stage.banner('绿野仙踪 · 谢谢你');
await stage.narrate('稻草人听懂了你带来的 Hello，高兴得直转圈，要和桃乐丝一起去找回家的路。');

stage.camera.dialog(dorothy, scarecrow);
await scarecrow.say('我要是有个聪明的脑袋，就能帮上更多忙啦！', 'spin');
await dorothy.say('You are already very clever, my friend!', 'nod');
await stage.narrate('桃乐丝说「你已经很聪明啦，我的朋友」。');

await stage.narrate('走着走着，路边站着一个生了锈的铁皮人，动都动不了。');
stage.camera.focus(tinman);
await tinman.say('我在这儿好久啦……谁能帮我上点油，我就能给你们指路。', 'shiver');
await stage.narrate('大家帮铁皮人上了油，他咔哒咔哒动了起来，指出了通往翡翠城的路。');

await dorothy.say('Thank you! You are so kind!', 'bounce');
await stage.narrate('桃乐丝想谢谢铁皮人。她说「谢谢你，你真好」。你帮她把这句 Thank you 带给铁皮人好不好？');

stage.camera.reset();
stage.end({ praise: '去跟铁皮人说 Thank you 吧！' });
