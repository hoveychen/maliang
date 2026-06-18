import { createHash, randomUUID } from 'node:crypto';
import type { Character } from './types.ts';
import type { ImageBlob } from './adapters/types.ts';

export interface World {
  id: string;
  characters: Map<string, Character>;
}

/** MVP 内存存储：世界状态 + 生成的 sprite 资源。后续换成 muvee dataset / DB。 */
export class WorldStore {
  private readonly worlds = new Map<string, World>();
  private readonly assets = new Map<string, ImageBlob>();

  createWorld(id: string = randomUUID()): World {
    const world: World = { id, characters: new Map() };
    this.worlds.set(id, world);
    return world;
  }

  getWorld(id: string): World | undefined {
    return this.worlds.get(id);
  }

  addCharacter(character: Character): void {
    const world = this.worlds.get(character.worldId);
    if (!world) throw new Error(`world not found: ${character.worldId}`);
    world.characters.set(character.id, character);
  }

  listCharacters(worldId: string): Character[] {
    return [...(this.worlds.get(worldId)?.characters.values() ?? [])];
  }

  getCharacter(worldId: string, characterId: string): Character | undefined {
    return this.worlds.get(worldId)?.characters.get(characterId);
  }

  /** 存入资源，返回内容寻址 hash。 */
  putAsset(blob: ImageBlob): string {
    const hash = createHash('sha256').update(blob.bytes).digest('hex').slice(0, 16);
    this.assets.set(hash, blob);
    return hash;
  }

  getAsset(hash: string): ImageBlob | undefined {
    return this.assets.get(hash);
  }
}
