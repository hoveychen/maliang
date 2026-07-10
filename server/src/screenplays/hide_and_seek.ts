// 躲猫猫 —— 游戏型剧本：事件驱动 + HUD 计分/倒计时 + 抓到就换鬼 + 胜负收场。
// 手写样本（P8），用来磨 Stage SDK 的手感；Plan 2 起由 LLM 照 stage_sdk.d.ts 生成同形状的脚本。
//
// 这是一段异步函数体（顶层 await 合法），不是模块：没有 import/export，全局只有 stage / cast。
// 旋钮 stage.params：hideSec 藏身时长 / gameSec 一局时长 / catchDist 抓到判定距离（世界坐标）。

const hideSec = Number(stage.params.hideSec ?? 10);
const gameSec = Number(stage.params.gameSec ?? 60);
const catchDist = Number(stage.params.catchDist ?? 2);

const seeker = stage.actors.find((a) => !a.isPlayer)!;
const kid = stage.player!;
if (!seeker || !kid) throw new Error('躲猫猫要一个当鬼的小伙伴和一个小朋友');

const score = stage.hud.score('抓到');
const timer = stage.hud.countdown(gameSec);
timer.onDone(() => {
  seeker.stop();
  stage.end({ winner: kid.name, praise: `${kid.name}藏得真好，一直没被抓到！` });
});

await stage.narrate(`躲猫猫开始啦！${seeker.name}当鬼，${kid.name}快躲好！`);
stage.camera.focus(kid);
await stage.sleep(hideSec);

// 第一轮：鬼来抓。先布判定再放鬼——订阅先于 follow 抵达服务端，第一帧就不会漏抓。
await stage.narrate(`${seeker.name}来抓人咯！`);
const caught = stage.once('near', seeker, kid, catchDist);
seeker.follow(kid);
await caught;
seeker.stop();
score.add(1);
stage.hud.toast('抓到啦！换你当鬼～');

// 第二轮：换鬼——小朋友自己追，鬼开始逃。
await stage.narrate(`换${kid.name}当鬼啦，${seeker.name}快跑！`);
const gotcha = stage.once('near', kid, seeker, catchDist);
seeker.flee(kid);
await gotcha;
seeker.stop();
score.add(1);

timer.cancel();
stage.end({ winner: kid.name, praise: `${kid.name}也抓到${seeker.name}啦，两个人都好厉害！` });
