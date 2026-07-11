import { Link } from 'react-router-dom';
import { fmtTs, useApi } from '../api.ts';
import type { ActivityResp } from '../types.ts';
import { Fallback, PageHead, ShortId } from '../components.tsx';

/** 会话时长（毫秒）→ 人读串。进行中为 —。 */
function fmtDuration(ms: number | null): string {
  if (ms === null) return '—';
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s} 秒`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} 分 ${s % 60} 秒`;
  return `${Math.floor(m / 60)} 时 ${m % 60} 分`;
}

/** 设备快照 → 一行紧凑描述（机型/系统优先，桌面回退到 UA 片段）。 */
function fmtDevice(d: ActivityResp['activity'][number]['device']): string {
  if (!d) return '—';
  const parts: string[] = [];
  if (d.model && d.model !== 'GenericDevice') parts.push(d.model);
  if (d.os) parts.push(d.osVersion ? `${d.os} ${d.osVersion}` : d.os);
  if (d.screen) parts.push(d.screen);
  return parts.length ? parts.join(' · ') : (d.ua ? d.ua.slice(0, 40) : '—');
}

/**
 * activity 记录：谁、用什么设备、何时来、玩多久。
 * 数据源是会话表（每次进世界一行）+ 建立时的设备快照。IP 只在这里给你自己看。
 */
export function ActivityPage() {
  const { data, error, loading, reload } = useApi<ActivityResp>('/debug/api/activity?limit=200');
  return (
    <>
      <PageHead
        title="活动记录"
        count={data?.total}
        desc="每次进世界一条：谁、用什么设备、何时来、玩多久。设备快照 = 服务端拿的 IP/UA + 客户端上报的机型/系统。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (data.activity.length === 0 ? (
        <div className="empty">还没有活动记录</div>
      ) : (
        <table className="grid">
          <thead>
            <tr>
              <th>时间</th><th>玩家</th><th>世界</th><th>时长</th>
              <th>设备</th><th>IP</th><th>系统 / 引擎</th>
            </tr>
          </thead>
          <tbody>
            {data.activity.map((a) => (
              <tr key={a.id}>
                <td className="mono">{fmtTs(a.startedAt)}</td>
                <td>
                  {a.playerName || <span className="empty-cell">匿名</span>}
                  <br />
                  <Link to={`/players/${a.playerId}`}><ShortId id={a.playerId} /></Link>
                </td>
                <td><Link to={`/worlds/${a.worldId}`}>{a.worldId}</Link></td>
                <td>
                  {a.endedAt === null
                    ? <span className="badge pine">进行中</span>
                    : <span className="mono">{fmtDuration(a.durationMs)}</span>}
                </td>
                <td>{fmtDevice(a.device)}</td>
                <td className="mono">{a.device?.ip ?? '—'}</td>
                <td className="mono aux">{a.device?.godot ? `Godot ${a.device.godot}` : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      ))}
      {data && data.total > data.activity.length && (
        <p className="page-desc aux">共 {data.total} 条，当前显示最近 {data.activity.length} 条。</p>
      )}
    </>
  );
}
