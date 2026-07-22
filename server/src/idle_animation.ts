// 角色动画的异步编排：源立绘 → 三段 Seedance 绿幕视频（idle/moving/talking）
// → 一张三段透明 sprite-sheet 图集 → 入库 + 记录。
// 慢（三段并发，仍要 60~120s），永远 fire-and-forget（triggerCharacterAnimation），
// 不进造角色/对话的同步闭环。
import type { ClipName, ImageBlob, ServiceAdapters, VideoBlob } from './adapters/types.ts';
import type { WorldStore } from './persistence.ts';
import { CLIP_NAMES, videosToSpriteSheet, type SpriteSheetMeta } from './sprite_sheet.ts';
import { mp4ToTheoraOgv, pregenerateClipOgv, type ToClipOgv } from './clip_video.ts';

/**
 * 当前图集版本。1 = 单段 idle（老记录，可能连 version 字段都没有）；2 = 三段。
 * 回填拿它当水位线：ready 但 version < 此值的记录要重跑。
 */
export const SPRITE_ANIM_VERSION = 2;

/**
 * 当前「打包管线」版本，与 SPRITE_ANIM_VERSION（结构版本）正交。
 * 1 = 绿边修复前的抠图；2 = 绿边去色溢修复（f365eab）后的抠图/打包；
 * 3 = 加产 24fps 高保真档图集（hiAnimAsset/hiMeta，角色动画 LOD 用）。
 * 抠图/去绿溢/帧率/裁剪盒等打包参数变了就 +1。回填据此判断哪些 ready 记录只需从存量原片
 * 零成本 repack（而非重新买视频）——见 backfillCharacterAnimations。
 *
 * ★为何 v3 是 packVersion bump 而非 SPRITE_ANIM_VERSION bump：24fps 变体从**已存原片**
 * 按不同 fps 参数重抽帧即得，零视频成本；结构（段名 idle/talking）没变。bump 结构版本会把
 * 存量记录推进「完整重生成（买视频）」路径，白烧钱——见 backfillCharacterAnimations 路①/②。
 */
export const SPRITE_PACK_VERSION = 3;

/** 底座档抽帧帧率（现状：idle 平缓，够顺又省显存）。远处 / 非最近 N 的角色用它。 */
export const LO_FPS = 8;
/**
 * 高保真档抽帧帧率 = 源片原生 24fps（Seedance 480p/24fps，clip_video.ts）。最近 N 个角色升到它，
 * 帧数 ×3、显存 ×3。图集无解码开销（区别于焦点真视频 LOD 的 ≤1-2 路解码限）。
 */
export const HI_FPS = 24;

/**
 * 视频→图集的转换缝（默认真实 ffmpeg 实现；测试注入假实现以免依赖网络/ffmpeg）。
 * fps 由调用方按档位传入（底座 LO_FPS / 高保真 HI_FPS）——同一批 clips 调两次产两档图集。
 */
export type ToSpriteSheet = (
  clips: { name: ClipName; mp4: VideoBlob }[],
  fps: number,
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
  toSpriteSheet: ToSpriteSheet = (clips, fps) => videosToSpriteSheet(clips, { fps }),
  toClipOgv: ToClipOgv = mp4ToTheoraOgv,
): Promise<void> {
  const sprite = store.getAsset(spriteHash);
  if (!sprite) return; // 立绘不在库里，无从生成
  store.setSpriteAnimPending(spriteHash);
  try {
    const mp4s = await Promise.all(
      CLIP_NAMES.map(async (name) => ({ name, mp4: await adapters.video.generateClip(sprite, name) })),
    );
    // 同一批原片打两档图集：底座 8fps（远处角色）+ 高保真 24fps（最近 N，角色动画 LOD）。
    const { atlas, meta } = await toSpriteSheet(mp4s, LO_FPS);
    const hi = await toSpriteSheet(mp4s, HI_FPS);
    const animAsset = store.putAsset(atlas);
    const hiAnimAsset = store.putAsset(hi.atlas);
    // 原片入库（内容寻址，重复内容天然去重）。放在图集之后：图集打不出来就没必要存原片。
    const clipVideos: Partial<Record<ClipName, string>> = {};
    for (const { name, mp4 } of mp4s) clipVideos[name] = store.putAsset(mp4);
    // 焦点视频 LOD：顺手把各段转成 ogv 预缓存，孩子首次对话即命中（尽力而为，失败留给端点惰转）。
    const clipOgv = await pregenerateClipOgv(store, mp4s, toClipOgv);
    store.setSpriteAnimReady(spriteHash, animAsset, meta, {
      version: SPRITE_ANIM_VERSION,
      packVersion: SPRITE_PACK_VERSION,
      clipVideos,
      clipOgv,
      hiAnimAsset,
      hiMeta: hi.meta,
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
  toSpriteSheet: ToSpriteSheet = (clips, fps) => videosToSpriteSheet(clips, { fps }),
  toClipOgv: ToClipOgv = mp4ToTheoraOgv,
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
  // 从存量原片零成本重打两档（底座 8fps + 高保真 24fps）——存量回填补 24fps 变体走这条路。
  const { atlas, meta } = await toSpriteSheet(clips, LO_FPS);
  const hi = await toSpriteSheet(clips, HI_FPS);
  const animAsset = store.putAsset(atlas);
  const hiAnimAsset = store.putAsset(hi.atlas);
  const clipOgv = await pregenerateClipOgv(store, clips, toClipOgv); // 重打时也刷新 ogv 预缓存
  store.setSpriteAnimReady(spriteHash, animAsset, meta, {
    version: SPRITE_ANIM_VERSION,
    packVersion: SPRITE_PACK_VERSION,
    clipVideos: vids,
    clipOgv,
    hiAnimAsset,
    hiMeta: hi.meta,
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
 * 存量回填：遍历所有世界的所有角色，凡其静态立绘的动画「不是当前版本」的，fire-and-forget 补一次。
 * 三条路（按代价从贵到便宜）：
 *   ①从未生成（无记录）或结构陈旧（version<当前，如新增段）→ 完整重生成（要向 Seedance 买视频）。
 *   ②只是打包管线陈旧（packVersion<当前，如绿边修复/换帧率）且存有原片 → 零成本 repack，不买视频。
 *   ③打包管线陈旧但无原片（v1 老记录）→ 只能回退完整重生成。
 * 结构+打包都已是当前 → 跳过。
 *
 * failed 一律不重试——避免坏立绘每次启动反复烧钱。pending 也跳过（正在跑）。
 * 同一立绘 hash 多角色共用时只触发一次。服务启动跑一次（buildServer 的 backfillOnBoot），返回触发条数。
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

      // ①无记录 / 结构陈旧 → 完整重生成（triggerCharacterAnimation 的去重看 version，此处必放行）。
      if (!rec || (rec.version ?? 1) < SPRITE_ANIM_VERSION) {
        triggerCharacterAnimation(adapters, store, hash, toSpriteSheet);
        triggered++;
        continue;
      }
      // 结构已是当前；只剩打包管线是否陈旧。
      if ((rec.packVersion ?? 1) >= SPRITE_PACK_VERSION) continue; // 全都当前 → 跳过
      if (rec.clipVideos) {
        // ②有原片 → 零成本 repack（version 已是当前，triggerCharacterAnimation 会跳过，故直接 repack）。
        void repackFromStoredClips(store, hash, toSpriteSheet).catch((err) =>
          console.warn(`回填 repack 失败 sprite=${hash}:`, err instanceof Error ? err.message : err),
        );
      } else {
        // ③无原片 → 只能重新买视频（同样绕过 triggerCharacterAnimation 的 version 去重）。
        void generateCharacterAnimation(adapters, store, hash, toSpriteSheet);
      }
      triggered++;
    }
  }
  return triggered;
}
