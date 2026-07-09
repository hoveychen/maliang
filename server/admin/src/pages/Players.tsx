import { fmtTs, useApi } from '../api.ts';
import type { PlayerRow } from '../types.ts';
import { Fallback, PageHead, RowLink, ShortId, Sprite } from '../components.tsx';

export function PlayersPage() {
  const { data, error, loading, reload } = useApi<{ players: PlayerRow[] }>('/debug/api/players');
  return (
    <>
      <PageHead
        title="玩家"
        count={data?.players.length}
        desc="设备端建档的小朋友（id = 设备稳定 UUID）。点行进详情。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (data.players.length === 0 ? (
        <div className="empty">还没有玩家建档</div>
      ) : (
        <table className="grid">
          <thead>
            <tr><th>形象</th><th>名字</th><th>称呼</th><th>性别</th><th>喜欢的颜色</th><th>会话数</th><th>最近上线</th><th>建档</th><th>id</th></tr>
          </thead>
          <tbody>
            {data.players.map((p) => (
              <RowLink to={`/players/${p.id}`} key={p.id}>
                <td><Sprite hash={p.spriteAsset} alt={p.name} /></td>
                <td><b>{p.name || '—'}</b></td>
                <td>{p.nickname || '—'}</td>
                <td>{p.gender === 'girl' ? '女孩' : p.gender === 'boy' ? '男孩' : p.gender || '—'}</td>
                <td>{p.color || '—'}</td>
                <td className="num-cell">{p.visitCount}</td>
                <td className="mono">{fmtTs(p.lastVisitAt)}</td>
                <td className="mono">{p.createdAt ? p.createdAt.slice(0, 10) : '—'}</td>
                <td><ShortId id={p.id} /></td>
              </RowLink>
            ))}
          </tbody>
        </table>
      ))}
    </>
  );
}
