/**
 * Stage SDK 类型声明 —— 剧本(screenplay)作者面对的全部 API，也是 Plan 2 喂给 LLM 的接口契约。
 *
 * 剧本是一段「异步函数体」：顶层可直接 await，沙箱里只有 stage / cast / console.log，
 * 没有 require/process/fetch/timers。运行时把它剥类型后丢进 node:vm 执行(server/src/stage_runner.ts)。
 *
 * 本文件与 screenplays/*.ts 一起被 tsconfig.json 的 exclude 排除在主工程之外
 * (剧本有顶层 await、引用全局 stage，不是模块)；它们的类型检查由
 * server/test/screenplay_typecheck.test.ts 用 TS 编译器 API 单独跑。
 *
 * 实现: server/src/stage_worker.ts   设计: docs/script-runtime-design.md
 */

/** 世界坐标（与 positions_report / near 判定同一套格子坐标系）。 */
interface Vec2 {
  x: number;
  y: number;
}

/** 落点：地点名（'pond'，由客户端解析成 POI）或世界坐标。 */
type Spot = string | Vec2;

/** 取消订阅。 */
type Unsub = () => void;

interface Actor {
  readonly id: string;
  readonly name: string;
  /** 小朋友本人扮演的角色（他的 avatar 由本端模拟，没有 TTS 音色）。 */
  readonly isPlayer: boolean;
  /** 走到落点，走到了才 resolve。 */
  moveTo(target: Spot): Promise<void>;
  /** 说一句（用该角色自己的音色），可带一个动作；说完才 resolve。 */
  say(text: string, action?: string): Promise<void>;
  /**
   * 做一个动作，做完才 resolve。26 种纸片动作：
   * wave挥手 jump跳 spin转圈 nod点头 flip翻跟头 backflip后空翻 cartwheel侧手翻
   * twirl芭蕾旋 helicopter直升机旋 paperflip翻面 peek侧身隐身 lie_down躺平
   * faceplant扑街 curl_up卷纸筒 shiver发抖 wiggle扭扭舞 puff挺胸鼓气
   * bounce弹弹球 squish拍扁 stretch长高高 fold对折 bow_fold折纸鞠躬
   * corner_wink折角卖萌 paper_plane纸飞机 accordion风琴折 crumple_ball揉纸团
   * （其他名字会退化成 wave，别自造）。
   */
  do(action: string): Promise<void>;
  /** 设置型：持续跟随，客户端本地跑，不逐帧过网。发出即返回。 */
  follow(target: Actor): void;
  /** 设置型：持续逃离。发出即返回。 */
  flee(from: Actor): void;
  /** 设置型：停下 follow/flee。发出即返回。 */
  stop(): void;
}

/** 计分板句柄。 */
interface Counter {
  add(n?: number): void;
}

/** 倒计时句柄。 */
interface Timer {
  /** 归零回调（客户端计时，归零才上行一次）。 */
  onDone(fn: () => void): Unsub;
  cancel(): void;
}

interface Prop {
  readonly id: string;
}

/**
 * 判定区域：世界坐标里的一个圆（圆心 + 半径）。用 `stage.region(...)` 造，喂给 `on/once('enter')`。
 * P1 只支持显式坐标——生成层（Plan 2）按世界 POI 注入 `x/y/r`（同 params 套路，坐标不写死在剧本里）。
 * 按地点名解析 POI（`region('goal')`）需要服务端 POI 表，是后续工作。
 */
interface Region {
  readonly id: string;
  readonly x: number;
  readonly y: number;
  readonly r: number;
}

/** 收场结果，客户端拿去做奖励结算/夸奖。 */
interface StageResult {
  winner?: string;
  praise?: string;
  [k: string]: unknown;
}

interface Stage {
  /** 参演角色表（含小朋友）。 */
  readonly actors: readonly Actor[];
  /** 小朋友本人（没有玩家参演时为 null）。 */
  readonly player: Actor | null;
  /**
   * 开演时注入的旋钮：难度、时长、判定距离等。用 `Number(stage.params.x ?? 默认值)` 读，
   * 缺省不炸——剧本必须在没有任何 params 时也能自己跑起来。
   */
  readonly params: Readonly<Record<string, unknown>>;

  /** 旁白一句（小仙子的声音），念完才 resolve。 */
  narrate(text: string): Promise<void>;
  /** 屏幕横幅（幕次提示），发出即返回。 */
  banner(text: string): void;
  /** 等 sec 秒。 */
  sleep(sec: number): Promise<void>;
  /** 小朋友的戏份：横幅提词 + 开麦，返回他说的那句话（没说出话则空串）。 */
  prompt(actor: Actor, hint: string): Promise<string>;
  /** 收场。可在事件回调里调用；调用后脚本立即终止。 */
  end(result?: StageResult): void;

  /** 定义一个判定区域（世界坐标圆）。喂给 `on/once('enter')` 做「进入区域」判定，如球门、安全区。 */
  region(area: { x: number; y: number; r: number }): Region;

  readonly prop: {
    /** 现场造一个道具（服务端造物管线出规格），落位后 resolve。 */
    create(desc: string, near: Actor | Spot): Promise<Prop>;
    /** 把道具挪到落点，挪到了才 resolve。 */
    place(id: string, at: Spot): Promise<void>;
    /** 撤掉道具，发出即返回。 */
    remove(id: string): void;
  };

  readonly hud: {
    score(label: string): Counter;
    /** 倒计时；双端读数由服务端时戳对齐。 */
    countdown(sec: number): Timer;
    toast(text: string): void;
  };

  /** 运镜，纯观感，发出即返回。 */
  readonly camera: {
    focus(a: Actor): void;
    overview(): void;
    dialog(a: Actor, b: Actor): void;
    reset(): void;
  };

  /** a、b 靠近到 dist 以内触发（服务端对复制位置求值；远→近边沿一次，分开后可再触发）。 */
  on(ev: 'near', a: Actor, b: Actor, dist: number, fn: (payload: { dist: number }) => void): Unsub;
  /** obj 进入 region 触发（服务端对复制位置求值；外→内边沿一次，离开后可再触发）。 */
  on(ev: 'enter', obj: Actor, region: Region, fn: (payload: { dist: number }) => void): Unsub;
  /** 小朋友点到某个角色时触发（客户端探测）。 */
  on(ev: 'tap', a: Actor, fn: (payload: { actorId: string }) => void): Unsub;

  /**
   * 一次性事件：await 到它发生（首次触发即退订），把游戏脚本写成直线。
   * 惯用法是「先布判定，再放角色」——订阅先于设置型命令抵达，第一帧就不会漏判：
   *   const caught = stage.once('near', seeker, kid, 2);
   *   seeker.follow(kid);
   *   await caught;
   */
  once(ev: 'near', a: Actor, b: Actor, dist: number): Promise<{ dist: number }>;
  once(ev: 'enter', obj: Actor, region: Region): Promise<{ dist: number }>;
  once(ev: 'tap', a: Actor): Promise<{ actorId: string }>;
}

declare const stage: Stage;

/** 按角色名选角；名字对不上直接抛错（生成层保证名字来自 stage.actors）。 */
declare function cast(...names: string[]): Actor[];

/** 沙箱里唯一的宿主对象：日志回传 ScriptRunner，供调试。没有 require/process/fetch/setTimeout。 */
declare const console: { log(...args: unknown[]): void };
