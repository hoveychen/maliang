// 三幕小剧场《丑小鸭》—— 剧场型剧本：顺序旁白 + 并行走位 + 现场造道具 + 运镜。
// 手写样本（P8），用来磨 Stage SDK 的手感；Plan 2 起由 LLM 逐幕生成同形状的脚本。
//
// 这是一段异步函数体（顶层 await 合法），不是模块：没有 import/export，全局只有 stage / cast。
// 旋钮 stage.params：pond/lake 两个落点名（生成层按当前场景的 POI 注入）。

const [duck, mama, swan] = cast('丑小鸭', '鸭妈妈', '天鹅');
const pond = String(stage.params.pond ?? 'pond');
const lake = String(stage.params.lake ?? 'lake');

// —— 第一幕 ——
stage.camera.overview();
stage.banner('第一幕 · 池塘边的鸭妈妈');
await stage.narrate('从前，池塘边住着鸭妈妈一家。');
await Promise.all([duck.moveTo(pond), mama.moveTo(pond)]); // 并行走位：都到齐才开演
const egg = await stage.prop.create('一颗大大的蛋', mama);
await mama.say('我的孩子们要出壳啦！', 'wave');

// —— 第二幕 ——
stage.banner('第二幕 · 谁都笑他丑');
await stage.narrate('小鸭子一个个破壳而出，可有一只，长得和大家都不一样。');
stage.prop.remove(egg.id); // 蛋壳碎了
stage.camera.dialog(duck, mama);
await duck.say('大家都笑我长得丑……', 'cry');
await mama.say('孩子，别难过，你会长大的。');

// —— 第三幕 ——
stage.banner('第三幕 · 冬去春来');
await stage.narrate('冬去春来，丑小鸭一个人熬过了长长的冬天。');
const mirror = await stage.prop.create('一面亮亮的小镜子', duck);
await stage.prop.place(mirror.id, lake);
await Promise.all([duck.moveTo(lake), swan.moveTo(lake)]);
await swan.say('你不是丑小鸭呀，你是一只美丽的天鹅！', 'wave');
await duck.do('spin');

stage.camera.reset();
stage.end({ praise: '演得真棒！' });
