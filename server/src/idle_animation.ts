// 立绘 idle 动画的异步编排：源立绘 → Seedance 绿幕视频 → 透明 sprite-sheet 图集 → 入库 + 记录。
// 慢（60~90s），永远 fire-and-forget（triggerIdleAnimation），不进造角色/对话的同步闭环。
import type { ServiceAdapters, VideoBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { videoToSpriteSheet, type SpriteSheetMeta } from './sprite_sheet.ts';
import type { ImageBlob } from './adapters/types.ts';

/** 视频→图集的转换缝（默认真实 ffmpeg 实现；测试注入假实现以免依赖网络/ffmpeg）。 */
export type ToSpriteSheet = (
  mp4: VideoBlob,
) => Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }>;

/**
 * 同步执行一次：源立绘 hash → 生成 idle 动画图集并入库、置 ready。
 * 失败置 failed（客户端保留静态立绘，不崩）。调用方一般用 triggerIdleAnimation 异步跑。
 */
export async function generateIdleAnimation(
  adapters: ServiceAdapters,
  store: WorldStore,
  spriteHash: string,
  toSpriteSheet: ToSpriteSheet = (mp4) => videoToSpriteSheet(mp4),
): Promise<void> {
  const sprite = store.getAsset(spriteHash);
  if (!sprite) return; // 立绘不在库里，无从生成
  store.setSpriteAnimPending(spriteHash);
  try {
    const mp4 = await adapters.video.generateIdleAnimation(sprite);
    const { atlas, meta } = await toSpriteSheet(mp4);
    const animAsset = store.putAsset(atlas);
    store.setSpriteAnimReady(spriteHash, animAsset, meta);
  } catch (err) {
    store.setSpriteAnimFailed(spriteHash);
    console.warn(`idle 动画生成失败 sprite=${spriteHash}:`, err instanceof Error ? err.message : err);
  }
}

/**
 * fire-and-forget 触发 idle 动画生成。已 pending/ready 则跳过（去重，省钱省算力）。
 * 造完静态立绘后调用，立即返回，不阻塞。
 */
export function triggerIdleAnimation(
  adapters: ServiceAdapters,
  store: WorldStore,
  spriteHash: string,
  toSpriteSheet?: ToSpriteSheet,
): void {
  const existing = store.getSpriteAnim(spriteHash);
  if (existing && (existing.status === 'pending' || existing.status === 'ready')) return;
  void generateIdleAnimation(adapters, store, spriteHash, toSpriteSheet);
}

/**
 * 存量回填：遍历所有世界的所有角色，凡其静态立绘「尚无任何 idle 动画记录」（status none）的，
 * fire-and-forget 触发一次生成。已有记录（pending/ready/failed）一律跳过——failed 不重试，避免坏立绘
 * 每次启动反复烧钱。用于把「造角色流程上线前就预种进世界的村民」补上动画，之后走 anim 优先只拉图集。
 * 同一立绘 hash 多角色共用时只触发一次。服务启动跑一次（buildServer 的 backfillOnBoot），返回触发条数。
 */
export function backfillIdleAnimations(
  adapters: ServiceAdapters,
  store: WorldStore,
  toSpriteSheet?: ToSpriteSheet,
): number {
  let triggered = 0;
  const seen = new Set<string>();
  for (const w of store.listWorlds()) {
    for (const c of store.listCharacters(w.id)) {
      const hash = c.appearance?.spriteAsset;
      if (!hash || seen.has(hash)) continue;
      seen.add(hash);
      if (store.getSpriteAnim(hash)) continue; // 已有记录（含 failed）→ 跳过，只补从未尝试过的
      triggerIdleAnimation(adapters, store, hash, toSpriteSheet);
      triggered++;
    }
  }
  return triggered;
}
