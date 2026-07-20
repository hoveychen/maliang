// M2 主线剧情编排（docs/m2-story-director-design.md §3）：章回幕状态机，纯逻辑。
//
//   idle ─搭话触发→ performing ─演出 done→ interacting ─互动完成→ rewarded ─→ 下一幕 idle
//     ▲                │ abort/timeout/断线/世界空                              │
//     └────────────────┘（进度纹丝不动＝回本幕幕首，重触发从头重演）             └─ 最后一幕 → 整册完结（settled）
//
// performing 只在内存，绝不落库：崩溃/断线/重启后读回的永远是幕首 idle（或互动中）。
// 无互动的幕（尾声谢幕）演出 done 直接走推进/完结，不经 interacting。
// stage 启动函数注入——P2 接 startStoryAsync 直供 StageStartOpts，单测注 mock；本模块不 import 舞台。

import type { StageRunResult } from './stage_types.ts';
import type { WorldStore } from './persistence.ts';
import type { StoryBookProgress } from './types.ts';
import { STORY_BOOKS, type StoryBook } from './story_books.ts';

/** 开演一幕。resolve 即演出收场：done＝演完，其余（abort/timeout/error/killed）＝中断。 */
export type StoryStageStarter = (args: {
  worldId: string;
  playerId: string;
  book: StoryBook;
  chapter: number;
}) => Promise<StageRunResult>;

export type StoryTriggerOutcome =
  | { status: 'refused'; reason: 'unknown_book' | 'bad_chapter' | 'stage_busy' }
  /** 已在互动幕：不重演，P2 让 gate 角色提醒去完成互动。 */
  | { status: 'interacting'; chapter: number }
  /**
   * 演出跑完。outcome：interacting＝进互动幕；aborted＝中断回幕首；
   * completed＝无互动的幕直接收场（尾声），advance 带推进结果。
   */
  | {
      status: 'performed';
      chapter: number;
      outcome: 'interacting' | 'aborted' | 'completed';
      /** 重看已发过奖的幕（收场时不再发奖）。 */
      rewatch: boolean;
      /** 仅 outcome=completed：本幕收场的推进结果。 */
      advance?: StoryAdvanceOutcome;
    };

/** 一幕收场（发奖点）的结果。P4 据 reward 决定盖章/贴纸，据 settledNow 触发入住。 */
export interface StoryAdvanceOutcome {
  bookId: string;
  chapter: number;
  /** 本次要发奖吗（重看已 rewarded 的幕＝false，防重复发奖的唯一判据）。 */
  reward: boolean;
  /** 游标推进了吗（只有前沿幕会推进；重看旧幕不动游标）。 */
  advanced: boolean;
  /** 本次收场让整册完结了（入住时刻，恰好一次）。 */
  settledNow: boolean;
  /**
   * 推进到的下一幕是「无互动幕」（谢幕尾声）时带上它的幕号——server 据此自动接演，
   * 不必让孩子走回 gate 角色再搭话（M2 尾声 UX：零玩法的谢幕不该要手动跑一趟）。
   * 只在 advanced 且未 settled 且下一幕无 interaction 时置；否则不带此字段。
   */
  autoPlayNextChapter?: number;
}

export class StoryDirector {
  #store: WorldStore;
  #startStage: StoryStageStarter;
  #books: Record<string, StoryBook>;
  /** 每世界至多一场章回演出（与 stage_session 一世界一场同口径；纯内存＝performing 不落库）。 */
  #performing = new Map<string, { playerId: string; bookId: string; chapter: number }>();

  constructor(store: WorldStore, startStage: StoryStageStarter, books: Record<string, StoryBook> = STORY_BOOKS) {
    this.#store = store;
    this.#startStage = startStage;
    this.#books = books;
  }

  /** 某世界是否正有章回在演（P2 拿去挡并发触发/普通演出撞车）。 */
  isPerforming(worldId: string): boolean {
    return this.#performing.has(worldId);
  }

  /** 某玩家某册的进度快照（P2 意图分流/P5 POI 提示用；无进度返回幕首空进度）。 */
  bookProgress(worldId: string, playerId: string, bookId: string): StoryBookProgress {
    return this.#store.getStoryProgress(worldId, playerId).books[bookId] ?? freshBookProgress();
  }

  /**
   * 搭话触发：从幕首开演一幕，等演出收场后迁状态。
   * 选幕：缺省演游标前沿；整册 settled 后缺省从第 1 幕重看；
   * 显式 rewatchChapter 只许已发过奖的幕（防跳幕剧透）。
   */
  async trigger(worldId: string, playerId: string, bookId: string, rewatchChapter?: number): Promise<StoryTriggerOutcome> {
    const book = this.#books[bookId];
    if (!book || book.chapters.length === 0) return { status: 'refused', reason: 'unknown_book' };
    if (this.#performing.has(worldId)) return { status: 'refused', reason: 'stage_busy' };
    const bp = this.bookProgress(worldId, playerId, bookId);
    if (bp.state === 'interacting') return { status: 'interacting', chapter: bp.activeChapter ?? bp.chapter };

    let chapter: number;
    if (rewatchChapter !== undefined) {
      if (!bp.rewarded.includes(rewatchChapter) || rewatchChapter >= book.chapters.length) {
        return { status: 'refused', reason: 'bad_chapter' };
      }
      chapter = rewatchChapter;
    } else if (bp.settled || bp.chapter >= book.chapters.length) {
      chapter = 0; // 整册看完还想听 → 从头重看
    } else {
      chapter = bp.chapter;
    }
    const rewatch = bp.rewarded.includes(chapter);

    this.#performing.set(worldId, { playerId, bookId, chapter });
    let result: StageRunResult;
    try {
      result = await this.#startStage({ worldId, playerId, book, chapter });
    } catch (e) {
      result = { status: 'error', message: e instanceof Error ? e.message : String(e) };
    } finally {
      this.#performing.delete(worldId);
    }

    // 中断：不落任何中间态，进度纹丝不动＝回幕首（重触发从头重演）
    if (result.status !== 'done') return { status: 'performed', chapter, outcome: 'aborted', rewatch };

    // 无互动的幕（尾声谢幕）：done 即收场，直接走推进/完结
    if (!book.chapters[chapter].interaction) {
      const advance = this.#settleChapter(worldId, playerId, book, chapter, /*fromInteracting=*/ false);
      return { status: 'performed', chapter, outcome: 'completed', rewatch, advance };
    }

    // done → interacting（落库，断线回来还认账；activeChapter 记住演的是哪幕——重看旧幕时 ≠ 游标）
    const sp = this.#store.getStoryProgress(worldId, playerId);
    const cur = sp.books[bookId] ?? freshBookProgress();
    cur.state = 'interacting';
    cur.activeChapter = chapter;
    sp.books[bookId] = cur;
    this.#store.setStoryProgress(worldId, playerId, sp);
    return { status: 'performed', chapter, outcome: 'interacting', rewatch };
  }

  /**
   * 互动完成（P4 storyTask 结算点调用）：interacting → 发奖 → 推进游标/完结。
   * 非 interacting 态返回 null（重复结算/脏调用一律不发奖——幂等）。
   */
  completeInteraction(worldId: string, playerId: string, bookId: string): StoryAdvanceOutcome | null {
    const book = this.#books[bookId];
    if (!book) return null;
    const bp = this.#store.getStoryProgress(worldId, playerId).books[bookId];
    if (!bp || bp.state !== 'interacting') return null;
    return this.#settleChapter(worldId, playerId, book, bp.activeChapter ?? bp.chapter, /*fromInteracting=*/ true);
  }

  /** 世界清空/断连清场（P2 接线）：只清内存演出标记；在飞的演出 promise 自己会以 abort 收尾。 */
  clearWorld(worldId: string): void {
    this.#performing.delete(worldId);
  }

  /**
   * 一幕收场（唯一发奖点）：rewarded[] 判重 → 前沿幕推进游标 → 最后一幕置 settled（恰好一次）。
   * fromInteracting＝互动幕收场（要把 interacting 归位 idle）；否则是无互动幕直接收场。
   */
  #settleChapter(worldId: string, playerId: string, book: StoryBook, chapter: number, fromInteracting: boolean): StoryAdvanceOutcome {
    const sp = this.#store.getStoryProgress(worldId, playerId);
    const bp = sp.books[book.id] ?? freshBookProgress();
    const reward = !bp.rewarded.includes(chapter);
    let advanced = false;
    let settledNow = false;
    if (reward) {
      bp.rewarded.push(chapter);
      if (chapter === bp.chapter) {
        bp.chapter += 1;
        advanced = true;
        if (bp.chapter >= book.chapters.length && !bp.settled) {
          bp.settled = true;
          settledNow = true;
        }
      }
    }
    if (fromInteracting) bp.state = 'idle';
    delete bp.activeChapter;
    sp.books[book.id] = bp;
    this.#store.setStoryProgress(worldId, playerId, sp);
    // 推进到的下一幕若是无互动幕（谢幕尾声），带上它的幕号让 server 自动接演——
    // 零玩法的谢幕不该要孩子走回 gate 角色再搭话（M2 尾声 UX）。整册已 settled 则没有下一幕。
    const autoPlayNextChapter =
      advanced && !settledNow && bp.chapter < book.chapters.length && !book.chapters[bp.chapter].interaction
        ? bp.chapter
        : undefined;
    return {
      bookId: book.id,
      chapter,
      reward,
      advanced,
      settledNow,
      ...(autoPlayNextChapter !== undefined ? { autoPlayNextChapter } : {}),
    };
  }
}

function freshBookProgress(): StoryBookProgress {
  return { chapter: 0, state: 'idle', rewarded: [], settled: false };
}
