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
