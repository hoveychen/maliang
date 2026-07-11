import { useApi } from '../api.ts';
import { STAMPS_PER_FLOWER, TASK_TYPE_LABELS, type Wallet, type WorldRow } from '../types.ts';
import { Fallback, PageHead, RowLink, ShortId } from '../components.tsx';

/** 钱包一行摘要：小红花数 + 未结算盖章进度。 */
export function walletSummary(wallet: Wallet): string {
  return `🌸×${wallet.flowers} · 章 ${wallet.stampProgress}/${STAMPS_PER_FLOWER}`;
}

/** 钱包/委托按玩家分后的行主标签：匿名连接共用 playerId=''。 */
export function playerLabel(playerId: string) {
  return playerId ? <ShortId id={playerId} /> : <span className="empty-cell">匿名</span>;
}

export function WorldsPage() {
  const { data, error, loading, reload } = useApi<{ worlds: WorldRow[] }>('/debug/api/worlds');
  return (
    <>
      <PageHead
        title="世界"
        count={data?.worlds.length}
        desc="每个世界一行：角色/物品/会话计数与进行中的委托。点行进详情。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (data.worlds.length === 0 ? (
        <div className="empty">还没有世界</div>
      ) : (
        <table className="grid">
          <thead>
            <tr><th>id</th><th>角色</th><th>物品</th><th>会话（进行中/总）</th><th>钱包（花/章）</th><th>进行中委托</th><th>地点</th></tr>
          </thead>
          <tbody>
            {data.worlds.map((w) => (
              <RowLink to={`/worlds/${w.id}`} key={w.id}>
                <td><b>{w.id}</b></td>
                <td className="num-cell">{w.characterCount}{w.fairyCount > 0 && <span className="mono"> (仙×{w.fairyCount})</span>}</td>
                <td className="num-cell">{w.itemCount}</td>
                <td className="num-cell">{w.activeVisitCount > 0 ? <b>{w.activeVisitCount}</b> : 0}/{w.visitCount}</td>
                <td className="mono">
                  {w.wallets.length === 0
                    ? <span className="empty-cell">—</span>
                    : w.wallets.map((e) => (
                        <div key={e.playerId}>{playerLabel(e.playerId)} {walletSummary(e.wallet)}</div>
                      ))}
                </td>
                <td>
                  {w.activeTasks.length === 0
                    ? <span className="empty-cell">无</span>
                    : w.activeTasks.map((e) => (
                        <div key={e.playerId}>
                          <span className="badge seal">{TASK_TYPE_LABELS[e.task.type] ?? e.task.type} · {e.task.npcName}</span>
                        </div>
                      ))}
                </td>
                <td className="mono">{w.locations.join('、') || '—'}</td>
              </RowLink>
            ))}
          </tbody>
        </table>
      ))}
    </>
  );
}
