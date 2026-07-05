import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { ActiveTask, Character, WorldProp } from './types.ts';
import type { ImageBlob } from './adapters/types.ts';

export interface World {
  id: string;
  characters: Map<string, Character>;
  /** 玩家的贴纸收集册：贴纸 id → 数量（委托奖励累积，可转赠扣减）。 */
  inventory: Record<string, number>;
  /** 进行中的 NPC 委托（至多一个，见 types.ActiveTask）。 */
  activeTask: ActiveTask | null;
  /** 语音生成的 SDF 物件（id → WorldProp，tile 为落位回报）。 */
  props: Map<string, WorldProp>;
}

/**
 * 世界状态 + 生成的 sprite 资源存储。
 * 传 dataDir → 持久化到磁盘（worlds.json + assets/ + assets.json 清单）；
 * 不传 → 纯内存（测试用）。后续可换 muvee dataset / DB。
 */
export class WorldStore {
  readonly #dir: string | null;
  readonly #worlds = new Map<string, World>();
  readonly #assets = new Map<string, ImageBlob>();
  // 世界地点名清单（POI，客户端 world_info 上报）：纯内存，客户端每次连上重发，不持久化
  readonly #locations = new Map<string, string[]>();

  constructor(dataDir?: string) {
    this.#dir = dataDir ?? null;
    if (this.#dir !== null) this.#load();
  }

  #assetsDir(): string {
    return join(this.#dir as string, 'assets');
  }

  #load(): void {
    const wf = join(this.#dir as string, 'worlds.json');
    if (existsSync(wf)) {
      const data = JSON.parse(readFileSync(wf, 'utf8')) as {
        worlds: Array<{ id: string; characters: Character[]; inventory?: Record<string, number>; activeTask?: ActiveTask | null; props?: Array<Omit<WorldProp, 'state'> & { state?: WorldProp['state'] }> }>;
      };
      for (const w of data.worlds) {
        const map = new Map<string, Character>();
        for (const c of w.characters) map.set(c.id, c);
        // 旧存档没有背包/委托/物件字段：给默认值，向后兼容（物件缺 state 视为已摆放）
        const props = new Map<string, WorldProp>();
        for (const p of w.props ?? []) props.set(p.id, { ...p, state: p.state ?? 'placed' });
        this.#worlds.set(w.id, { id: w.id, characters: map, inventory: w.inventory ?? {}, activeTask: w.activeTask ?? null, props });
      }
    }
    const mf = join(this.#dir as string, 'assets.json');
    if (existsSync(mf)) {
      const mimes = JSON.parse(readFileSync(mf, 'utf8')) as Record<string, string>;
      for (const hash of Object.keys(mimes)) {
        const p = join(this.#assetsDir(), hash);
        if (existsSync(p)) this.#assets.set(hash, { bytes: new Uint8Array(readFileSync(p)), mime: mimes[hash]! });
      }
    }
  }

  #persistWorlds(): void {
    if (this.#dir === null) return;
    mkdirSync(this.#dir, { recursive: true });
    const worlds = [...this.#worlds.values()].map((w) => ({
      id: w.id,
      characters: [...w.characters.values()],
      inventory: w.inventory,
      activeTask: w.activeTask,
      props: [...w.props.values()],
    }));
    writeFileSync(join(this.#dir, 'worlds.json'), JSON.stringify({ worlds }, null, 2));
  }

  #persistAssetIndex(): void {
    if (this.#dir === null) return;
    const idx: Record<string, string> = {};
    for (const [hash, blob] of this.#assets) idx[hash] = blob.mime;
    writeFileSync(join(this.#dir, 'assets.json'), JSON.stringify(idx));
  }

  createWorld(id: string = randomUUID()): World {
    const world: World = { id, characters: new Map(), inventory: {}, activeTask: null, props: new Map() };
    this.#worlds.set(id, world);
    this.#persistWorlds();
    return world;
  }

  getWorld(id: string): World | undefined {
    return this.#worlds.get(id);
  }

  addCharacter(character: Character): void {
    const world = this.#worlds.get(character.worldId);
    if (!world) throw new Error(`world not found: ${character.worldId}`);
    world.characters.set(character.id, character);
    this.#persistWorlds();
  }

  /** 角色状态变更后持久化（如 chatHistory/behaviorScript 更新）。 */
  saveCharacter(character: Character): void {
    const world = this.#worlds.get(character.worldId);
    if (world) world.characters.set(character.id, character);
    this.#persistWorlds();
  }

  /** 语音生成的 SDF 物件：新增（tile 待客户端落位回报）。 */
  addProp(worldId: string, prop: WorldProp): void {
    const world = this.#worlds.get(worldId);
    if (!world) throw new Error(`world not found: ${worldId}`);
    world.props.set(prop.id, prop);
    this.#persistWorlds();
  }

  /** 客户端落位回报：记下物件的 tile，重载世界时按此恢复。 */
  setPropTile(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#worlds.get(worldId)?.props.get(propId);
    if (!prop) return false;
    prop.tile = tile;
    this.#persistWorlds();
    return true;
  }

  /** 收纳：已摆物件收进收集册物品页（tile 清空）。不存在或已在背包 → false 不动账。 */
  storeProp(worldId: string, propId: string): boolean {
    const prop = this.#worlds.get(worldId)?.props.get(propId);
    if (!prop || prop.state !== 'placed') return false;
    prop.state = 'bagged';
    prop.tile = null;
    this.#persistWorlds();
    return true;
  }

  /** 摆出：背包物件放回世界指定 tile（客户端已过占地校验）。不存在或不在背包 → false。 */
  takeProp(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#worlds.get(worldId)?.props.get(propId);
    if (!prop || prop.state !== 'bagged') return false;
    prop.state = 'placed';
    prop.tile = tile;
    this.#persistWorlds();
    return true;
  }

  /** 挪位：已摆物件换 tile（长按拖拽后回报）。不存在或在背包 → false。 */
  movePropTile(worldId: string, propId: string, tile: [number, number]): boolean {
    const prop = this.#worlds.get(worldId)?.props.get(propId);
    if (!prop || prop.state !== 'placed') return false;
    prop.tile = tile;
    this.#persistWorlds();
    return true;
  }

  listProps(worldId: string): WorldProp[] {
    return [...(this.#worlds.get(worldId)?.props.values() ?? [])];
  }

  /** 客户端上报的世界地点名（喂给意图 LLM 让「去某地」说的是真实地名）。 */
  setLocations(worldId: string, names: string[]): void {
    this.#locations.set(worldId, names);
  }

  getLocations(worldId: string): string[] {
    return this.#locations.get(worldId) ?? [];
  }

  // ── 奖赏系统：玩家贴纸背包 + 进行中委托 ──────────────────────────────────

  getInventory(worldId: string): Record<string, number> {
    return this.#worlds.get(worldId)?.inventory ?? {};
  }

  /** 发贴纸（委托奖励）。 */
  addSticker(worldId: string, stickerId: string, n = 1): void {
    const world = this.#worlds.get(worldId);
    if (!world) return;
    world.inventory[stickerId] = (world.inventory[stickerId] ?? 0) + n;
    this.#persistWorlds();
  }

  /** 扣贴纸（转赠/gift 委托）。不够扣返回 false 且不动账。 */
  removeSticker(worldId: string, stickerId: string, n = 1): boolean {
    const world = this.#worlds.get(worldId);
    if (!world || (world.inventory[stickerId] ?? 0) < n) return false;
    world.inventory[stickerId] = (world.inventory[stickerId] ?? 0) - n;
    if (world.inventory[stickerId] === 0) delete world.inventory[stickerId];
    this.#persistWorlds();
    return true;
  }

  getActiveTask(worldId: string): ActiveTask | null {
    return this.#worlds.get(worldId)?.activeTask ?? null;
  }

  setActiveTask(worldId: string, task: ActiveTask | null): void {
    const world = this.#worlds.get(worldId);
    if (!world) return;
    world.activeTask = task;
    this.#persistWorlds();
  }

  listCharacters(worldId: string): Character[] {
    return [...(this.#worlds.get(worldId)?.characters.values() ?? [])];
  }

  getCharacter(worldId: string, characterId: string): Character | undefined {
    return this.#worlds.get(worldId)?.characters.get(characterId);
  }

  /** 存入资源，返回内容寻址 hash。 */
  putAsset(blob: ImageBlob): string {
    const hash = createHash('sha256').update(blob.bytes).digest('hex').slice(0, 16);
    this.#assets.set(hash, blob);
    if (this.#dir !== null) {
      mkdirSync(this.#assetsDir(), { recursive: true });
      writeFileSync(join(this.#assetsDir(), hash), Buffer.from(blob.bytes));
      this.#persistAssetIndex();
    }
    return hash;
  }

  getAsset(hash: string): ImageBlob | undefined {
    return this.#assets.get(hash);
  }
}
