// 《绿野仙踪》第一幕 · 黄砖路上的问候（第一季册 5，docs/season-1-outline.md §4）。
// 英语暴露：桃乐丝天生说英文，点点用中文轻声「翻译」（ambient，不跟读不打分，英语纪律 §138）。
// 尾随互动：task:deliver——帮桃乐丝把 'Hello!' 带给玉米地里的稻草人（孩子说中文也算完成）。
// 台词与 assets/voice/story_oz/lines.json 一一对应（英文避撇号：story_content.test 用单引号抠台词）。

const [dorothy] = cast('桃乐丝');

stage.camera.overview();
stage.banner('绿野仙踪 · 黄砖路');
await stage.narrate('一阵好大的风，把一个小姑娘吹到了这条金黄色的砖头路上。');

stage.camera.focus(dorothy);
await dorothy.say('Hello! I am Dorothy. Where am I?', 'wave');
await stage.narrate('她说的是英文哦。点点悄悄告诉你：她说「你好呀，我叫桃乐丝，我在哪儿呀」。');

await dorothy.say('I want to go home. Can you help me?', 'puff');
await stage.narrate('桃乐丝想回家啦。她说「我想回家，你可以帮帮我吗」。');

await stage.narrate('顺着黄砖路往前看，玉米地里站着一个稻草人，正朝这边笑呢。');
await dorothy.say('Look! A friend! Let us say hello!', 'bounce');
await stage.narrate('桃乐丝说「看！一个朋友！我们去打个招呼吧」。你帮她把这句英文的问候带给稻草人好不好？');

stage.camera.reset();
stage.end({ praise: '一起去跟稻草人说 Hello 吧！' });
