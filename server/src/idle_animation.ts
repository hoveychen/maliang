// 角色动画的异步编排：源立绘 → 三段 Seedance 绿幕视频（idle/moving/talking）
// → 一张三段透明 sprite-sheet 图集 → 入库 + 记录。
// 慢（三段并发，仍要 60~120s），永远 fire-and-forget（triggerCharacterAnimation），
// 不进造角色/对话的同步闭环。
import type { ClipName, ImageBlob, ServiceAdapters, VideoBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { CLIP_NAMES, videosToSpriteSheet, type SpriteSheetMeta } from './sprite_sheet.ts';

/**
 * 当前图集版本。1 = 单段 idle（老记录，可能连 version 字段都没有）；2 = 三段。
 * 回填拿它当水位线：ready 但 version < 此值的记录要重跑。
 */
export const SPRITE_ANIM_VERSION = 2;

/** 视频→图集的转换缝（默认真实 ffmpeg 实现；测试注入假实现以免依赖网络/ffmpeg）。 */
export type ToSpriteSheet = (
  clips: { name: ClipName; mp4: VideoBlob }[],
) => Promise<{ atlas: ImageBlob; meta: SpriteSheetMeta }>;

/**
 * 同步执行一次：源立绘 hash → 生成三段动画、打成一张图集入库、置 ready。
 * 失败置 failed（客户端保留静态立绘，不崩）。调用方一般用 triggerCharacterAnimation 异步跑。
 *
 * 三段并发生成（每段一次计费）。原始 mp4 一并入库并记进 clipVideos——图集的帧率/打包参数
 * 日后还会调，存了原片就能纯本地重抽帧，不必再向 Seedance 买一遍（见 SpriteAnimRecord）。
 */
export async function generateCharacterAnimation(
  adapters: ServiceAdapters,
  store: WorldStore,
  spriteHash: string,
  toSpriteSheet: ToSpriteSheet = (clips) => videosToSpriteSheet(clips),
): Promise<void> {
  const sprite = store.getAsset(spriteHash);
  if (!sprite) return; // 立绘不在库里，无从生成
  store.setSpriteAnimPending(spriteHash);
  try {
    const mp4s = await Promise.all(
      CLIP_NAMES.map(async (name) => ({ name, mp4: await adapters.video.generateClip(sprite, name) })),
    );
    const { atlas, meta } = await toSpriteSheet(mp4s);
    const animAsset = store.putAsset(atlas);
    // 原片入库（内容寻址，重复内容天然去重）。放在图集之后：图集打不出来就没必要存原片。
    const clipVideos: Partial<Record<ClipName, string>> = {};
    for (const { name, mp4 } of mp4s) clipVideos[name] = store.putAsset(mp4);
    store.setSpriteAnimReady(spriteHash, animAsset, meta, {
      version: SPRITE_ANIM_VERSION,
      clipVideos,
    });
  } catch (err) {
    store.setSpriteAnimFailed(spriteHash);
    console.warn(`角色动画生成失败 sprite=${spriteHash}:`, err instanceof Error ? err.message : err);
  }
}

/**
 * 从已存的原片重打图集：不碰视频生成、零成本。用于换帧率/换打包参数后刷新存量图集。
 * 缺原片（v1 老记录、或某段没存下来）→ 返回 false，调用方该走完整重生成。
 */
export async function repackFromStoredClips(
  store: WorldStore,
  spriteHash: string,
  toSpriteSheet: ToSpriteSheet = (clips) => videosToSpriteSheet(clips),
): Promise<boolean> {
  const vids = store.getSpriteAnim(spriteHash)?.clipVideos;
  if (!vids) return false;
  const clips: { name: ClipName; mp4: VideoBlob }[] = [];
  for (const name of CLIP_NAMES) {
    const hash = vids[name];
    if (!hash) return false;
    const blob = store.getAsset(hash);
    if (!blob) return false; // 记录里有 hash 但盘上没字节 —— 当缺原片处理
    clips.push({ name, mp4: blob });
  }
  const { atlas, meta } = await toSpriteSheet(clips);
  const animAsset = store.putAsset(atlas);
  store.setSpriteAnimReady(spriteHash, animAsset, meta, {
    version: SPRITE_ANIM_VERSION,
    clipVideos: vids,
  });
  return true;
}

/**
 * fire-and-forget 触发动画生成。已 pending / 已是当前版本的 ready 则跳过（去重，省钱省算力）。
 * 造完静态立绘后调用，立即返回，不阻塞。
 */
export function triggerCharacterAnimation(
  adapters: ServiceAdapters,
  store: WorldStore,
  spriteHash: string,
  toSpriteSheet?: ToSpriteSheet,
): void {
  const existing = store.getSpriteAnim(spriteHash);
  if (existing?.status === 'pending') return;
  if (existing?.status === 'ready' && (existing.version ?? 1) >= SPRITE_ANIM_VERSION) return;
  void generateCharacterAnimation(adapters, store, spriteHash, toSpriteSheet);
}

/**
 * 存量回填：遍历所有世界的所有角色，凡其静态立绘「没有当前版本的动画」的，fire-and-forget
 * 触发一次生成。覆盖两种：①从未生成过（无记录）②旧版单段 idle 图集（ready 但 version<2）。
 *
 * failed 一律不重试——避免坏立绘每次启动反复烧钱。pending 也跳过（正在跑）。
 * 同一立绘 hash 多角色共用时只触发一次。服务启动跑一次（buildServer 的 backfillOnBoot），
 * 返回触发条数。
 */
export function backfillCharacterAnimations(
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
      const rec = store.getSpriteAnim(hash);
      if (rec && rec.status !== 'ready') continue; // pending 在跑 / failed 不重试
      if (rec?.status === 'ready' && (rec.version ?? 1) >= SPRITE_ANIM_VERSION) continue;
      triggerCharacterAnimation(adapters, store, hash, toSpriteSheet);
      triggered++;
    }
  }
  return triggered;
}
