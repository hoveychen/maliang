// 剧本系统共享类型：ScriptRunner(宿主) 与 stage_worker(沙箱) 之间的消息协议。
// 设计文档: docs/script-runtime-design.md

/** 参演角色的静态信息（注入沙箱，供 cast()/stage.actors 使用）。 */
export interface StageActorInfo {
  id: string;
  name: string;
  isPlayer: boolean;
  /** 该角色 TTS 音色（clientTts：随 stage_begin 下发，客户端 say 用它本地合成）。玩家无音色可省。 */
  voiceId?: string;
}

/** 沙箱脚本发出的一条舞台命令。op 对 Runner 透明，由 StageBackend 解释。 */
export interface StageCommand {
  cmdId: number;
  actorId?: string;
  op: string;
  args: Record<string, unknown>;
}

/** 沙箱脚本注册的一个事件订阅（near/tap/timer 等）。 */
export interface StageSubscription {
  subId: string;
  ev: string;
  params: Record<string, unknown>;
}

/** 一次剧本运行的最终结果。 */
export type StageRunResult =
  | { status: 'done'; result?: Record<string, unknown> }
  | { status: 'error'; message: string }
  | { status: 'timeout' }
  | { status: 'killed' };

/** worker → 宿主 的消息。 */
export type WorkerToHostMsg =
  | { kind: 'cmd'; cmdId: number; actorId?: string; op: string; args: Record<string, unknown> }
  | { kind: 'subscribe'; subId: string; ev: string; params: Record<string, unknown> }
  | { kind: 'unsubscribe'; subId: string }
  | { kind: 'done'; result?: Record<string, unknown> }
  | { kind: 'error'; message: string }
  | { kind: 'log'; text: string };

/** 宿主 → worker 的消息。 */
export type HostToWorkerMsg =
  | { kind: 'ack'; cmdId: number; result?: Record<string, unknown>; error?: string }
  | { kind: 'event'; subId: string; payload?: Record<string, unknown> };

/** 传给 worker 的启动数据（结构化克隆）。 */
export interface StageWorkerData {
  /** 已剥离 TS 类型的脚本 JS 源码。 */
  code: string;
  actors: StageActorInfo[];
  /** 脚本累计可发出的命令上限（防失控）。 */
  maxCommands: number;
}

/** 舞台后端：把命令翻译成真实演出（P1 用 mock，P3 起接 WS 舞台协议）。 */
export interface StageBackend {
  /** 执行一条命令；resolve 即 ack（脚本侧对应的 await 返回）。 */
  execCommand(cmd: StageCommand): Promise<Record<string, unknown> | void>;
  /** 脚本注册/注销事件订阅时的通知（可选，用于在客户端布置检测器）。 */
  onSubscribe?(sub: StageSubscription): void;
  onUnsubscribe?(subId: string): void;
}

/**
 * 舞台造物：把剧本里的 prop.create(desc) 翻成服务端造物管线生成的道具规格。
 * 剧本道具不走小红花经济（非孩子付费造角色），失败返回 null（execCommand 侧转 stage_abort）。
 */
export type StagePropMaker = (worldId: string, desc: string) => Promise<{ id: string; spec: unknown } | null>;
