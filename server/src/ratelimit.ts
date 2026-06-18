// 昂贵操作（造角色/语音，走付费 API）的限流：每 key 滑动窗口 + 全局并发上限。
// 防止公开端点被刷爆成本。纯内存，单实例够用（MVP）。

export interface AcquireOk {
  ok: true;
  release: () => void;
}
export interface AcquireDenied {
  ok: false;
  reason: string;
}
export type AcquireResult = AcquireOk | AcquireDenied;

const WINDOW_MS = 60_000;

export class RateLimiter {
  readonly #perMin: number;
  readonly #globalMax: number;
  #globalActive = 0;
  readonly #buckets = new Map<string, number[]>();

  constructor(perMin: number, globalMax: number) {
    this.#perMin = perMin;
    this.#globalMax = globalMax;
  }

  get activeCount(): number {
    return this.#globalActive;
  }

  /**
   * 尝试占用一个名额。成功返回 release()（操作结束务必调用以释放全局并发）；
   * 失败返回友好中文拒绝原因（每连接限频 或 全局繁忙）。
   */
  tryAcquire(key: string, now: number): AcquireResult {
    const arr = this.#buckets.get(key) ?? [];
    const fresh = arr.filter((t) => now - t < WINDOW_MS);
    if (fresh.length >= this.#perMin) {
      this.#buckets.set(key, fresh);
      return { ok: false, reason: '玩得太快啦，歇一会儿再来～' };
    }
    if (this.#globalActive >= this.#globalMax) {
      this.#buckets.set(key, fresh);
      return { ok: false, reason: '好多小朋友在一起玩，稍等一下下～' };
    }
    fresh.push(now);
    this.#buckets.set(key, fresh);
    this.#globalActive++;
    let released = false;
    return {
      ok: true,
      release: () => {
        if (!released) {
          released = true;
          this.#globalActive--;
        }
      },
    };
  }
}
