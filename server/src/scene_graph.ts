/**
 * 场景连通图上的寻路（fairy-guide P3）—— 见 docs/scene-portal-graph-design.md、docs/fairy-guide-design.md。
 *
 * 13 个场景由 ~40 条有向 portal 边连成一张图（每个场景 ~3 个传送点，双向互指），BFS 可达性
 * 早有客户端测试（test/test_portal.gd）盯着，但服务端一直没有寻路代码——引路是第一个需要它的地方。
 *
 * 规模：13 节点 / ~40 边。每次现算，不做缓存。
 */
import type { WorldStore } from './persistence.ts';
import type { GuideLeg } from './types.ts';
import { MAX_GUIDE_LEGS } from './types.ts';

/**
 * 从 from 走到 to 的最短 portal 路径（逐跳：在哪个场景、走哪个传送点、通向哪儿）。
 *
 * - from === to → 返回 []（同场景，不用走门）
 * - 不可达 → null
 * - 超过 MAX_GUIDE_LEGS 跳 → null（老板拍板：3-5 岁小朋友扛不住长途跋涉，宁可让她说「太远啦」）
 */
export function routeScenes(store: WorldStore, worldId: string, from: string, to: string): GuideLeg[] | null {
  if (from === to) return [];

  const scenes = store.listScenes(worldId);
  const byId = new Map(scenes.map((s) => [s.sceneId, s]));
  if (!byId.has(from) || !byId.has(to)) return null;

  // BFS：队列里存「走到这个场景的完整路径」，第一次碰到 to 即最短。
  const seen = new Set<string>([from]);
  let frontier: { sceneId: string; path: GuideLeg[] }[] = [{ sceneId: from, path: [] }];

  while (frontier.length > 0) {
    const next: typeof frontier = [];
    for (const cur of frontier) {
      for (const portal of byId.get(cur.sceneId)?.portals ?? []) {
        if (seen.has(portal.toScene)) continue;
        const path: GuideLeg[] = [
          ...cur.path,
          {
            sceneId: cur.sceneId,
            portalTile: { tileX: portal.tile[0], tileY: portal.tile[1] },
            toScene: portal.toScene,
          },
        ];
        // 超长的路径连扩都不扩：它的任何延伸只会更长。
        if (path.length > MAX_GUIDE_LEGS) continue;
        if (portal.toScene === to) return path;
        seen.add(portal.toScene);
        next.push({ sceneId: portal.toScene, path });
      }
    }
    frontier = next;
  }
  return null; // 不可达，或最短路超过 MAX_GUIDE_LEGS
}
