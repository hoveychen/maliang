// 多人基座：world 维度的连接注册表 + 广播。
// 每个 WS 连接经 world_info 登记进所在世界；host(首位进入者)承担 NPC 模拟所有权
// (见 docs/script-runtime-design.md 多人架构节)，host 断线自动重指派。
// Hub 只管成员关系与派发，不懂协议语义——消息构造留在 server.ts。

export interface HubMember {
  /** 连接级唯一 id(server.ts 的 connKey)。 */
  clientId: string;
  playerId: string;
  send(msg: Record<string, unknown>): void;
}

export interface HubLeaveResult {
  worldId: string;
  /** 离开者曾是 host 且世界还有人 ⇒ 新任 host(需要通知它接管 NPC 模拟)。 */
  newHost: HubMember | null;
}

export class WorldHub {
  /** worldId → clientId → member；Map 插入序即加入序，首位即 host。 */
  #worlds = new Map<string, Map<string, HubMember>>();
  #clientWorld = new Map<string, string>();

  /** 进世界。已在别的世界 ⇒ 先离开(departed 携带旧世界的 host 变更)。重复 join 同世界只更新成员信息、保序。 */
  join(worldId: string, member: HubMember): { isHost: boolean; departed: HubLeaveResult | null } {
    let departed: HubLeaveResult | null = null;
    const prev = this.#clientWorld.get(member.clientId);
    if (prev && prev !== worldId) departed = this.leave(member.clientId);
    let members = this.#worlds.get(worldId);
    if (!members) {
      members = new Map();
      this.#worlds.set(worldId, members);
    }
    members.set(member.clientId, member); // 已存在时 Map 保插入序，只更新值
    this.#clientWorld.set(member.clientId, worldId);
    return { isHost: this.hostOf(worldId)?.clientId === member.clientId, departed };
  }

  /** 离开(leave_world / socket 断开)。返回 null = 本来就不在任何世界。 */
  leave(clientId: string): HubLeaveResult | null {
    const worldId = this.#clientWorld.get(clientId);
    if (!worldId) return null;
    this.#clientWorld.delete(clientId);
    const members = this.#worlds.get(worldId);
    if (!members) return { worldId, newHost: null };
    const wasHost = this.hostOf(worldId)?.clientId === clientId;
    members.delete(clientId);
    if (members.size === 0) {
      this.#worlds.delete(worldId);
      return { worldId, newHost: null };
    }
    return { worldId, newHost: wasHost ? this.hostOf(worldId) : null };
  }

  membersIn(worldId: string): HubMember[] {
    return [...(this.#worlds.get(worldId)?.values() ?? [])];
  }

  /** host = 现存成员中最早加入者。 */
  hostOf(worldId: string): HubMember | null {
    const members = this.#worlds.get(worldId);
    if (!members) return null;
    return members.values().next().value ?? null;
  }

  worldOf(clientId: string): string | null {
    return this.#clientWorld.get(clientId) ?? null;
  }

  /** 向世界内所有成员(可排除一人)派发消息；单个死连接不拖累其他人。返回送达数。 */
  broadcast(worldId: string, msg: Record<string, unknown>, exceptClientId?: string): number {
    let n = 0;
    for (const m of this.#worlds.get(worldId)?.values() ?? []) {
      if (m.clientId === exceptClientId) continue;
      try {
        m.send(msg);
        n++;
      } catch {
        // 发送失败的连接留给它自己的 close 事件清理
      }
    }
    return n;
  }
}
