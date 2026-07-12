// WS 舞台协议：把 ScriptRunner 的命令流桥接到 world 内的客户端。
// 下行: stage_begin / stage_cmd / stage_end / stage_abort (经 WorldHub 广播)
// 上行: stage_event { kind: 'ack' | 'abort' | ... } (P5 起扩 tap/timer/near)
// 一个世界同时只有一场演出；断连清空世界即杀 worker。
// 设计文档: docs/script-runtime-design.md

import { randomUUID } from 'node:crypto';
import { ScriptRunner } from './stage_runner.ts';
import type { StageActorInfo, StageBackend, StageCommand, StagePropMaker, StageRunResult, StageSubscription } from './stage_types.ts';
import type { WorldHub } from './world_hub.ts';

export interface StageStartOpts {
  code: string;
  actors: StageActorInfo[];
  timeoutMs?: number;
  cmdTimeoutMs?: number;
  maxCommands?: number;
  /** 注入脚本的旋钮（stage.params）。 */
  params?: Record<string, unknown>;
}

/** 客户端上行的舞台事件(handleWsMessage 解析后传入)。 */
export interface StageEventMsg {
  kind?: string;
  cmdId?: number;
  result?: Record<string, unknown>;
  error?: string;
  /** near/tap/timer 规则触发时携带的订阅 id（关联脚本里的 on(...)/countdown.onDone）。 */
  subId?: string;
  /** 事件负载（如 tap 的角色、near 的实时距离），注回脚本回调。 */
  payload?: Record<string, unknown>;
}

/** 服务端求值的规则订阅登记（near/enter：对复制位置单点判定，无双端分歧，不下发客户端探测器）。 */
export interface NearRegistry {
  add(subId: string, a: string, b: string, dist: number): void;
  /** enter：obj 进入以 (x,y) 为心、r 为半径的世界坐标圆。 */
  addEnter(subId: string, obj: string, x: number, y: number, r: number): void;
  /** 撤销订阅；返回 true 表示确是服务端求值订阅（near/enter，据此免发 unwatch）。 */
  remove(subId: string): boolean;
}

/** 把命令广播给世界成员、把 ack 关联回 Promise 的舞台后端。 */
class WsStageBackend implements StageBackend {
  #hub: WorldHub;
  #worldId: string;
  #stageId: string;
  #propMaker?: StagePropMaker;
  #near: NearRegistry;
  #pending = new Map<number, { resolve: (v?: Record<string, unknown>) => void; reject: (e: Error) => void }>();

  constructor(hub: WorldHub, worldId: string, stageId: string, near: NearRegistry, propMaker?: StagePropMaker) {
    this.#hub = hub;
    this.#worldId = worldId;
    this.#stageId = stageId;
    this.#near = near;
    this.#propMaker = propMaker;
  }

  execCommand(cmd: StageCommand): Promise<Record<string, unknown> | void> {
    // prop.create 不下发客户端（客户端造不出 spec）：服务端跑造物管线出 spec，
    // 再以 prop_spawn 携规格广播让客户端落位，客户端 ack 后 resolve 回脚本。
    if (cmd.op === 'prop_create') return this.#createProp(cmd);
    // 倒计时打服务端起始时戳：客户端按 serverStartMs + 时间偏移算本地截止，双端读数一致。
    if (cmd.op === 'hud_countdown') cmd.args = { ...cmd.args, serverStartMs: Date.now() };
    return this.#dispatch(cmd.cmdId, cmd.op, cmd.actorId, cmd.args);
  }

  /** 广播一条命令给世界成员，登记 pending 等客户端 ack（首个生效）。世界空则立即回绝。 */
  #dispatch(cmdId: number, op: string, actorId: string | undefined, args: Record<string, unknown>): Promise<Record<string, unknown> | void> {
    return new Promise((resolve, reject) => {
      this.#pending.set(cmdId, { resolve, reject });
      const n = this.#hub.broadcast(this.#worldId, { type: 'stage_cmd', stageId: this.#stageId, cmdId, actorId, op, args });
      if (n === 0) {
        this.#pending.delete(cmdId);
        reject(new Error('世界里没有观众了'));
      }
    });
  }

  async #createProp(cmd: StageCommand): Promise<Record<string, unknown>> {
    const prop = this.#propMaker ? await this.#propMaker(this.#worldId, String(cmd.args.desc ?? '')) : null;
    if (!prop) throw new Error('造物失败');
    // 复用原 cmdId：客户端把 prop_spawn 落位后 ack cmdId，resolve 回脚本的 prop.create。
    const res = await this.#dispatch(cmd.cmdId, 'prop_spawn', undefined, { id: prop.id, spec: prop.spec, near: cmd.args.near });
    return { id: prop.id, ...(res ?? {}) };
  }

  /**
   * 脚本订阅规则：near 挪到服务端对复制位置求值（登记进 NearRegistry，不下发客户端）；
   * tap/timer 仍广播 watch 让客户端布置本地探测器（无 ack，cmdId=-1）。
   */
  onSubscribe(sub: StageSubscription): void {
    if (sub.ev === 'near') {
      this.#near.add(sub.subId, String(sub.params.a ?? ''), String(sub.params.b ?? ''), Number(sub.params.dist ?? 0));
      return;
    }
    if (sub.ev === 'enter') {
      this.#near.addEnter(sub.subId, String(sub.params.obj ?? ''), Number(sub.params.x ?? 0), Number(sub.params.y ?? 0), Number(sub.params.r ?? 0));
      return;
    }
    this.#hub.broadcast(this.#worldId, {
      type: 'stage_cmd', stageId: this.#stageId, cmdId: -1, op: 'watch',
      args: { subId: sub.subId, ev: sub.ev, params: sub.params },
    });
  }

  onUnsubscribe(subId: string): void {
    if (this.#near.remove(subId)) return; // near 无客户端探测器，免发 unwatch
    this.#hub.broadcast(this.#worldId, { type: 'stage_cmd', stageId: this.#stageId, cmdId: -1, op: 'unwatch', args: { subId } });
  }

  /** 客户端回执；多客户端时首个 ack 生效，后续忽略。 */
  ack(cmdId: number, result?: Record<string, unknown>, error?: string): void {
    const p = this.#pending.get(cmdId);
    if (!p) return;
    this.#pending.delete(cmdId);
    if (error) p.reject(new Error(error));
    else p.resolve(result);
  }

  /** 演出结束：悬空的命令全部回绝，别让 runner 侧 Promise 泄漏。 */
  dispose(): void {
    for (const p of this.#pending.values()) p.reject(new Error('演出已结束'));
    this.#pending.clear();
  }
}

/** 一条 near 订阅的服务端求值状态。inside：上次是否已判定为「靠近」，用于边沿触发只在远→近时开火一次。 */
interface NearSub {
  a: string;
  b: string;
  dist: number;
  inside: boolean;
}

/** 一条 enter 订阅的服务端求值状态。区域是世界坐标圆 (x,y,r)；inside 语义同 NearSub。 */
interface EnterSub {
  obj: string;
  x: number;
  y: number;
  r: number;
  inside: boolean;
}

/** 复制位置一次更新（世界坐标）。 */
export interface PositionUpdate {
  id: string;
  x: number;
  y: number;
}

/** 一场进行中的演出。 */
class StageSession {
  readonly stageId = randomUUID();
  readonly runner: ScriptRunner;
  readonly backend: WsStageBackend;
  /** 参演角色静态信息（中途加入者快照回放 stage_begin 用）。 */
  actors: StageActorInfo[] = [];
  /** actorId → 最新复制到的世界坐标（各端 positions_report 喂入）。 */
  #positions = new Map<string, { x: number; y: number }>();
  /** subId → near 订阅状态。 */
  #nearSubs = new Map<string, NearSub>();
  /** subId → enter 订阅状态。 */
  #enterSubs = new Map<string, EnterSub>();

  constructor(hub: WorldHub, worldId: string, propMaker?: StagePropMaker) {
    const near: NearRegistry = {
      add: (subId, a, b, dist) => this.#nearSubs.set(subId, { a, b, dist, inside: false }),
      addEnter: (subId, obj, x, y, r) => this.#enterSubs.set(subId, { obj, x, y, r, inside: false }),
      // subId 只会落在一个表里；|| 短路即可，返回 true 表示是服务端求值订阅（免发 unwatch）。
      remove: (subId) => this.#nearSubs.delete(subId) || this.#enterSubs.delete(subId),
    };
    this.backend = new WsStageBackend(hub, worldId, this.stageId, near, propMaker);
    this.runner = new ScriptRunner(this.backend);
  }

  /**
   * 喂入复制位置并对所有 near 订阅求值。命中(远→近边沿)→注回脚本回调，携带实时距离。
   * 两端分开时复位 inside，让下一次靠近能再次触发（抓到→逃开→再抓到）。
   */
  updatePositions(updates: PositionUpdate[]): void {
    for (const u of updates) this.#positions.set(u.id, { x: u.x, y: u.y });
    for (const [subId, s] of this.#nearSubs) {
      const pa = this.#positions.get(s.a);
      const pb = this.#positions.get(s.b);
      if (!pa || !pb) continue;
      const d = Math.hypot(pa.x - pb.x, pa.y - pb.y);
      const near = d <= s.dist;
      if (near && !s.inside) {
        s.inside = true;
        this.runner.emitEvent(subId, { dist: d });
      } else if (!near && s.inside) {
        s.inside = false;
      }
    }
    // enter：obj 进入世界坐标圆 (x,y,r)。边沿语义同 near——外→内触发一次，离开后可再触发。
    for (const [subId, s] of this.#enterSubs) {
      const p = this.#positions.get(s.obj);
      if (!p) continue;
      const d = Math.hypot(p.x - s.x, p.y - s.y);
      const inside = d <= s.r;
      if (inside && !s.inside) {
        s.inside = true;
        this.runner.emitEvent(subId, { dist: d });
      } else if (!inside && s.inside) {
        s.inside = false;
      }
    }
  }
}

/** 每个 world 至多一场演出的调度台。 */
export class StageDirector {
  #hub: WorldHub;
  #propMaker?: StagePropMaker;
  #active = new Map<string, StageSession>();

  constructor(hub: WorldHub, propMaker?: StagePropMaker) {
    this.#hub = hub;
    this.#propMaker = propMaker;
  }

  activeIn(worldId: string): boolean {
    return this.#active.has(worldId);
  }

  /**
   * 中途加入快照：世界正在演出时，给刚进来的连接补发 stage_begin（锁交互 + 准备接收后续命令）。
   * 只回放静态开场（演员表）；进行中的 HUD/道具/走位靠后续广播的增量命令与位置流补齐——
   * 儿童沙盒对「错过前几秒」无感，不做完整状态重建。无演出则 no-op。
   */
  snapshotFor(worldId: string, send: (msg: Record<string, unknown>) => void): void {
    const session = this.#active.get(worldId);
    if (!session) return;
    send({ type: 'stage_begin', stageId: session.stageId, actors: session.actors });
  }

  /**
   * 开演：广播 stage_begin，跑完(自然收场/异常/超时/被杀)广播 stage_end 或 stage_abort。
   * 返回演出终局的 Promise(测试与上层可 await)；世界已有演出时返回 null。
   */
  startStage(worldId: string, opts: StageStartOpts): Promise<StageRunResult> | null {
    if (this.#active.has(worldId)) return null;
    const session = new StageSession(this.#hub, worldId, this.#propMaker);
    session.actors = opts.actors;
    this.#active.set(worldId, session);
    this.#hub.broadcast(worldId, {
      type: 'stage_begin',
      stageId: session.stageId,
      actors: opts.actors,
    });
    return session.runner
      .run({
        code: opts.code,
        actors: opts.actors,
        timeoutMs: opts.timeoutMs,
        cmdTimeoutMs: opts.cmdTimeoutMs,
        maxCommands: opts.maxCommands,
        params: opts.params,
      })
      .then((r) => {
        this.#finish(worldId, session, r);
        return r;
      });
  }

  /** 复制位置喂入（positions_report 转发点调用）：驱动服务端 near 求值。无演出则忽略。 */
  updatePositions(worldId: string, updates: PositionUpdate[]): void {
    this.#active.get(worldId)?.updatePositions(updates);
  }

  /** 客户端上行 stage_event 分发：ack 关联命令，abort 终止演出。 */
  handleStageEvent(worldId: string, ev: StageEventMsg): void {
    const session = this.#active.get(worldId);
    if (!session) return;
    if (ev.kind === 'ack' && typeof ev.cmdId === 'number') {
      session.backend.ack(ev.cmdId, ev.result, ev.error);
    } else if (ev.kind === 'abort') {
      session.runner.kill(); // 终局广播走 run().then 的统一收尾
    } else if ((ev.kind === 'near' || ev.kind === 'tap' || ev.kind === 'timer') && typeof ev.subId === 'string') {
      // 规则触发：客户端探测到（点角色/倒计时归零/靠近）→ 注回脚本对应订阅回调。
      session.runner.emitEvent(ev.subId, ev.payload);
    }
  }

  /** 世界没人了(最后一个连接断开/离开)：演出没有观众，杀掉。 */
  onWorldEmpty(worldId: string): void {
    this.#active.get(worldId)?.runner.kill();
  }

  #finish(worldId: string, session: StageSession, r: StageRunResult): void {
    if (this.#active.get(worldId) !== session) return; // 已被后续演出顶替(理论不可达，防御)
    this.#active.delete(worldId);
    session.backend.dispose();
    if (r.status === 'done') {
      this.#hub.broadcast(worldId, { type: 'stage_end', stageId: session.stageId, result: r.result });
    } else {
      const reason = r.status === 'error' ? r.message : r.status === 'timeout' ? '演出超时' : '演出被终止';
      this.#hub.broadcast(worldId, { type: 'stage_abort', stageId: session.stageId, reason });
    }
  }
}
