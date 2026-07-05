import { createHash, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Character } from './types.ts';
import type { ImageBlob } from './adapters/types.ts';

export interface World {
  id: string;
  characters: Map<string, Character>;
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
      const data = JSON.parse(readFileSync(wf, 'utf8')) as { worlds: Array<{ id: string; characters: Character[] }> };
      for (const w of data.worlds) {
        const map = new Map<string, Character>();
        for (const c of w.characters) map.set(c.id, c);
        this.#worlds.set(w.id, { id: w.id, characters: map });
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
    const worlds = [...this.#worlds.values()].map((w) => ({ id: w.id, characters: [...w.characters.values()] }));
    writeFileSync(join(this.#dir, 'worlds.json'), JSON.stringify({ worlds }, null, 2));
  }

  #persistAssetIndex(): void {
    if (this.#dir === null) return;
    const idx: Record<string, string> = {};
    for (const [hash, blob] of this.#assets) idx[hash] = blob.mime;
    writeFileSync(join(this.#dir, 'assets.json'), JSON.stringify(idx));
  }

  createWorld(id: string = randomUUID()): World {
    const world: World = { id, characters: new Map() };
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

  /** 客户端上报的世界地点名（喂给意图 LLM 让「去某地」说的是真实地名）。 */
  setLocations(worldId: string, names: string[]): void {
    this.#locations.set(worldId, names);
  }

  getLocations(worldId: string): string[] {
    return this.#locations.get(worldId) ?? [];
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
