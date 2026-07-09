import { Link } from 'react-router-dom';
import { fmtTs, useApi } from '../api.ts';
import type { Overview } from '../types.ts';
import { Fallback, PageHead, ShortId, Stats } from '../components.tsx';

export function OverviewPage() {
  const { data, error, loading, reload } = useApi<Overview>('/debug/api/overview');
  return (
    <>
      <PageHead
        title="总览"
        desc="世界运行状态一眼清。数据只读，直连 WorldStore。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (
        <>
          <Stats
            items={[
              { label: '玩家', num: data.players },
              { label: '世界', num: data.worlds },
              { label: '角色', num: data.characters },
              { label: '物品', num: data.props },
              {
                label: '会话（进行中/总）',
                num: (
                  <>
                    {data.visits.active}
                    <span className="aux">/{data.visits.total}</span>
                  </>
                ),
                accent: data.visits.active > 0,
              },
              { label: '造角色图标', num: data.creationIcons },
            ]}
          />
          <h2 className="sect">最近会话</h2>
          {data.recentVisits.length === 0 ? (
            <div className="empty">还没有会话记录</div>
          ) : (
            <table className="grid">
              <thead>
                <tr><th>世界</th><th>玩家</th><th>开始</th><th>结束</th><th>状态</th></tr>
              </thead>
              <tbody>
                {data.recentVisits.map((v) => (
                  <tr key={v.id}>
                    <td><Link to={`/worlds/${v.worldId}`}>{v.worldId}</Link></td>
                    <td>{v.playerId ? <Link to={`/players/${v.playerId}`}><ShortId id={v.playerId} /></Link> : <span className="empty-cell">匿名</span>}</td>
                    <td className="mono">{fmtTs(v.startedAt)}</td>
                    <td className="mono">{fmtTs(v.endedAt)}</td>
                    <td>{v.endedAt === null ? <span className="badge pine">进行中</span> : <span className="badge">已结束</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </>
  );
}
