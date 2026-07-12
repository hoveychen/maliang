// 踢球 —— C 档球玩法：可踢的球 + 服务端进球门判定 + 计分/胜负/倒计时。
// 手写样本（P4），验证「大多数玩法应是纯脚本」（docs/realtime-game-primitives-design §6.1）：
// 踢球本身【不写进剧本】——孩子靠近球即可踢（客户端原语 + 谁踢谁临时拥有的预测物理）；
// 剧本只管【规则】：生成球、划出两侧球门圆、球进门计分、时间到或先到分定胜负。
// Plan 2 起由 LLM 照 stage_sdk.d.ts 生成同形状的脚本。
//
// 这是一段异步函数体（顶层 await 合法），不是模块：没有 import/export，全局只有 stage / cast。
// 旋钮 stage.params（生成层按当前场景 POI 注入坐标，坐标不写死；缺省给一组能自跑的值）：
//   center 开球点 / goalRed·goalBlue 两侧球门圆 {x,y,r} / gameSec 一局时长 / winScore 提前获胜分。

const center: Spot = (stage.params.center as Spot | undefined) ?? { x: 75, y: 75 };
const goalRed = (stage.params.goalRed as { x: number; y: number; r: number } | undefined) ?? { x: 20, y: 75, r: 6 };
const goalBlue = (stage.params.goalBlue as { x: number; y: number; r: number } | undefined) ?? { x: 130, y: 75, r: 6 };
const gameSec = Number(stage.params.gameSec ?? 120);
const winScore = Number(stage.params.winScore ?? 3);

// 现场生成一个可踢的球，落到中场。红队守左门(goalRed)、蓝队守右门(goalBlue)：球进谁的门，对方得分。
const ball = await stage.spawnBall(center);
const gRed = stage.region(goalRed);
const gBlue = stage.region(goalBlue);
const redBoard = stage.hud.score('红队');
const blueBoard = stage.hud.score('蓝队');
let red = 0;
let blue = 0;

await stage.narrate('踢球开始啦！把球踢进对方的球门就得分，靠近球就能踢哦！');
const timer = stage.hud.countdown(gameSec);

// 游戏在「时间到」或「某队先到 winScore」时结束。进球 = 计分 + 庆祝 + 把球复位回中场再来一局。
// on('enter') 是服务端对复制的球位置求值（点对区域），进球判定中立公平，不靠任何一端说了算。
await new Promise<void>((resolve) => {
  let over = false;
  const finish = () => {
    if (over) return;
    over = true;
    resolve();
  };

  timer.onDone(finish);

  stage.on('enter', ball, gBlue, () => {
    if (over) return;
    red += 1;
    redBoard.add(1);
    stage.hud.toast(`红队进球！${red} : ${blue}`);
    if (red >= winScore) finish();
    else void ball.reset(center); // 复位是完成型（await 才落位），但回合内不必等——fire-and-forget
  });
  stage.on('enter', ball, gRed, () => {
    if (over) return;
    blue += 1;
    blueBoard.add(1);
    stage.hud.toast(`蓝队进球！${red} : ${blue}`);
    if (blue >= winScore) finish();
    else void ball.reset(center);
  });
});

timer.cancel();
const winner = red === blue ? '平局' : red > blue ? '红队' : '蓝队';
const praise = red === blue ? '踢成平局啦，两队都好厉害！' : `${winner}赢啦，踢得真棒！`;
stage.end({ winner, red, blue, praise });
