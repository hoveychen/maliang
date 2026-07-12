// 老鹰抓小鸡 —— A 档追逐玩法：链式跟随 + 服务端抓捕判定 + 逐只出局 + 收场。
// 手写样本（P4），验证「大多数玩法应是纯脚本」（docs/realtime-game-primitives-design §6.2）：
// 这个游戏【几乎不需要新原语】——链式 follow、鹰追队尾、near 抓捕全是现有 SDK。踢球才是唯一
// 需要新 C 档原语（球物理+预测+所有权转移）的驱动案例。此脚本就是那个假设的活证据。
// Plan 2 起由 LLM 照 stage_sdk.d.ts 生成同形状的脚本。
//
// 这是一段异步函数体（顶层 await 合法），不是模块：没有 import/export，全局只有 stage / cast。
// 旋钮 stage.params：catchDist 抓到判定距离（世界坐标）。角色表须含「老鹰」「母鸡」，其余非玩家
// 演员都当小鸡（数量不限）；有小朋友则母鸡带着小朋友领头。

const catchDist = Number(stage.params.catchDist ?? 2);
const eagle = cast('老鹰')[0];
const hen = cast('母鸡')[0];
// 小鸡 = 除老鹰/母鸡/小朋友外的所有演员（按 id 排除，数量不限）。
const chicks = stage.actors.filter((a) => !a.isPlayer && a.id !== eagle.id && a.id !== hen.id);
if (chicks.length === 0) throw new Error('老鹰抓小鸡至少要一只小鸡');

const caughtBoard = stage.hud.score('抓到');
await stage.narrate('老鹰抓小鸡开始啦！母鸡带着小鸡快跑，别被老鹰抓到！');

// 链式跟随（设置型，客户端本地跑不过网）：母鸡领头（有小朋友就跟小朋友，没有就自己站队头），
// 小鸡一个跟一个排成队。母鸡领头 → chicks[0] → chicks[1] → …
if (stage.player) hen.follow(stage.player);
chicks[0].follow(hen);
for (let i = 1; i < chicks.length; i++) chicks[i].follow(chicks[i - 1]);

// 一只只抓：鹰追当前队尾，抓到（near 服务端判定）就把队尾摘走、再追新队尾，直到小鸡抓光。
// 「先布判定再放鹰」——once 订阅先于 follow 抵达服务端，第一帧就不会漏抓。
const queue = [...chicks];
while (queue.length > 0) {
  const tail = queue[queue.length - 1];
  const caught = stage.once('near', eagle, tail, catchDist);
  eagle.follow(tail);
  await caught;
  eagle.stop();
  tail.stop(); // 被抓的小鸡退出队列，不再跟随
  queue.pop();
  caughtBoard.add(1);
  stage.hud.toast(`${tail.name}被抓住啦！`);
}

stage.end({ winner: '老鹰', caught: chicks.length, praise: '小鸡都被抓住啦，老鹰赢！再来一局？' });
