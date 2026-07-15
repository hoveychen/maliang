import { fmtTs, useApi } from '../api.ts';
import type { OnboardingProfile, PlayerRow } from '../types.ts';
import { Fallback, PageHead, RowLink, ShortId, Sprite } from '../components.tsx';

export function PlayersPage() {
  const { data, error, loading, reload } = useApi<{ players: PlayerRow[] }>('/debug/api/players');
  // onboarding 档案总表：players 表只收「进过世界」的玩家（world_info 才 upsert），
  // 刚建完形象还没进世界的孩子只存在于 player_onboarding——不并上会漏人。
  const ob = useApi<{ profiles: OnboardingProfile[] }>('/debug/api/onboarding-profiles');
  const knownIds = new Set((data?.players ?? []).map((p) => p.id));
  const onboardingOnly = (ob.data?.profiles ?? []).filter((p) => !knownIds.has(p.playerId));
  const obByPlayer = new Map((ob.data?.profiles ?? []).map((p) => [p.playerId, p]));
  return (
    <>
      <PageHead
        title="玩家"
        count={(data?.players.length ?? 0) + onboardingOnly.length}
        desc="设备端建档的小朋友（id = 设备稳定 UUID）。点行进详情；「档案」列 = 有 onboarding 创建形象档案。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (data.players.length === 0 && onboardingOnly.length === 0 ? (
        <div className="empty">还没有玩家建档</div>
      ) : (
        <table className="grid">
          <thead>
            <tr><th>形象</th><th>名字</th><th>称呼</th><th>性别</th><th>喜欢的颜色</th><th>档案</th><th>会话数</th><th>最近上线</th><th>建档</th><th>id</th></tr>
          </thead>
          <tbody>
            {data.players.map((p) => (
              <RowLink to={`/players/${p.id}`} key={p.id}>
                <td><Sprite hash={p.spriteAsset} alt={p.name} /></td>
                <td><b>{p.name || '—'}</b></td>
                <td>{p.nickname || '—'}</td>
                <td>{p.gender === 'girl' ? '女孩' : p.gender === 'boy' ? '男孩' : p.gender || '—'}</td>
                <td>{p.color || '—'}</td>
                <td>{obByPlayer.has(p.id) ? <span className="badge pine">onboarding</span> : <span className="empty-cell">—</span>}</td>
                <td className="num-cell">{p.visitCount}</td>
                <td className="mono">{fmtTs(p.lastVisitAt)}</td>
                <td className="mono">{p.createdAt ? p.createdAt.slice(0, 10) : '—'}</td>
                <td><ShortId id={p.id} /></td>
              </RowLink>
            ))}
            {onboardingOnly.map((p) => (
              <RowLink to={`/players/${p.playerId}`} key={p.playerId}>
                <td><Sprite hash={p.spriteAsset} alt={p.name} /></td>
                <td><b>{p.name || '—'}</b></td>
                <td>{p.nickname || '—'}</td>
                <td>{p.attrs.gender || '—'}</td>
                <td>{p.attrs.color || '—'}</td>
                <td><span className="badge">还没进过世界</span></td>
                <td className="num-cell">0</td>
                <td className="mono">—</td>
                <td className="mono">{p.createdAt ? p.createdAt.slice(0, 10) : '—'}</td>
                <td><ShortId id={p.playerId} /></td>
              </RowLink>
            ))}
          </tbody>
        </table>
      ))}
    </>
  );
}
