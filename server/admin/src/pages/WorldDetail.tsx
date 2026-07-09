import { Link, useParams, useSearchParams } from 'react-router-dom';
import { fmtTs, useApi } from '../api.ts';
import { STICKER_GLYPHS, TASK_TYPE_LABELS, type WorldDetail } from '../types.ts';
import { Fallback, PageHead, RowLink, ShortId, Sprite, Stats } from '../components.tsx';

const TABS = [
  { key: 'characters', label: '角色' },
  { key: 'props', label: '物品' },
  { key: 'events', label: '世界事件' },
  { key: 'inventory', label: '贴纸背包' },
] as const;

export function WorldDetailPage() {
  const { id = '' } = useParams();
  const [sp, setSp] = useSearchParams();
  const tab = sp.get('tab') ?? 'characters';
  const { data, error, loading, reload } = useApi<WorldDetail>(`/debug/api/worlds/${encodeURIComponent(id)}`);

  const counts: Record<string, number> = data
    ? {
        characters: data.characters.length,
        props: data.props.length,
        events: data.visits.length + (data.activeTask ? 1 : 0),
        inventory: Object.values(data.inventory).filter((n) => n > 0).length,
      }
    : {};

  return (
    <>
      <PageHead
        crumbs={<><Link to="/worlds">世界</Link> / {id}</>}
        title={`世界 ${id}`}
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (
        <>
          <Stats
            items={[
              { label: '角色', num: data.characterCount },
              { label: '物品', num: data.propCount },
              { label: '会话（进行中/总）', num: <>{data.activeVisitCount}<span className="aux">/{data.visitCount}</span></>, accent: data.activeVisitCount > 0 },
              { label: '地点', num: data.locations.length },
            ]}
          />
          <div className="tabs">
            {TABS.map((t) => (
              <button
                key={t.key}
                className={tab === t.key ? 'active' : ''}
                onClick={() => setSp({ tab: t.key }, { replace: true })}
              >
                {t.label}
                <span className="n">{counts[t.key] ?? 0}</span>
              </button>
            ))}
          </div>

          {tab === 'characters' && (
            data.characters.length === 0 ? <div className="empty">没有角色</div> : (
              <table className="grid">
                <thead>
                  <tr><th>立绘</th><th>名字</th><th>状态</th><th>位置</th><th>性格</th><th>记忆</th><th>对话</th><th>音色</th><th>id</th></tr>
                </thead>
                <tbody>
                  {data.characters.map((c) => (
                    <RowLink to={`/worlds/${id}/characters/${c.id}`} key={c.id}>
                      <td><Sprite hash={c.spriteAsset} alt={c.name} /></td>
                      <td><b>{c.name}</b>{c.isFairy && <span className="badge seal" style={{ marginLeft: 6 }}>仙</span>}</td>
                      <td><span className="badge">{c.state}</span></td>
                      <td className="mono">({c.position.tileX},{c.position.tileY})</td>
                      <td style={{ maxWidth: 260 }}>{c.personality.length > 40 ? c.personality.slice(0, 40) + '…' : c.personality}</td>
                      <td className="num-cell">{c.memoryCount}</td>
                      <td className="num-cell">{c.chatTurnCount}</td>
                      <td className="mono">{c.voiceId}</td>
                      <td><ShortId id={c.id} /></td>
                    </RowLink>
                  ))}
                </tbody>
              </table>
            )
          )}

          {tab === 'props' && (
            data.props.length === 0 ? <div className="empty">没有物品</div> : (
              <table className="grid">
                <thead><tr><th>名字</th><th>状态</th><th>位置</th><th>id</th><th>spec</th></tr></thead>
                <tbody>
                  {data.props.map((p) => (
                    <tr key={p.id}>
                      <td><b>{String(p.spec.name ?? '（未命名）')}</b></td>
                      <td>{p.state === 'placed' ? <span className="badge pine">摆放中</span> : <span className="badge">已收纳</span>}</td>
                      <td className="mono">{p.tile ? `(${p.tile[0]},${p.tile[1]})` : '—'}</td>
                      <td><ShortId id={p.id} /></td>
                      <td>
                        <details>
                          <summary className="mono" style={{ cursor: 'pointer' }}>展开 spec</summary>
                          <pre className="code">{JSON.stringify(p.spec, null, 2)}</pre>
                        </details>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )
          )}

          {tab === 'events' && (
            <>
              <h2 className="sect" style={{ marginTop: 4 }}>进行中委托</h2>
              {data.activeTask ? (
                <div className="panel">
                  <dl className="kv">
                    <dt>类型</dt><dd><span className="badge seal">{TASK_TYPE_LABELS[data.activeTask.type] ?? data.activeTask.type}</span></dd>
                    <dt>委托人</dt><dd>{data.activeTask.npcName} <ShortId id={data.activeTask.npcId} /></dd>
                    {data.activeTask.targetName && <><dt>对象</dt><dd>{data.activeTask.targetName}</dd></>}
                    {data.activeTask.locationName && <><dt>地点</dt><dd>{data.activeTask.locationName}</dd></>}
                    {data.activeTask.message && <><dt>要带的话</dt><dd>{data.activeTask.message}</dd></>}
                    {data.activeTask.itemId && <><dt>要送的贴纸</dt><dd>{STICKER_GLYPHS[data.activeTask.itemId] ?? data.activeTask.itemId}</dd></>}
                    <dt>奖励</dt><dd>{STICKER_GLYPHS[data.activeTask.rewardId] ?? data.activeTask.rewardId}</dd>
                  </dl>
                </div>
              ) : <div className="empty">当前没有进行中的委托</div>}

              <h2 className="sect">会话（Visit）</h2>
              {data.visits.length === 0 ? <div className="empty">还没有会话</div> : (
                <table className="grid">
                  <thead><tr><th>玩家</th><th>开始</th><th>结束</th><th>状态</th></tr></thead>
                  <tbody>
                    {[...data.visits].sort((a, b) => b.startedAt - a.startedAt).map((v) => (
                      <tr key={v.id}>
                        <td>{v.playerId ? <Link to={`/players/${v.playerId}`}><ShortId id={v.playerId} /></Link> : <span className="empty-cell">匿名</span>}</td>
                        <td className="mono">{fmtTs(v.startedAt)}</td>
                        <td className="mono">{fmtTs(v.endedAt)}</td>
                        <td>{v.endedAt === null ? <span className="badge pine">进行中</span> : <span className="badge">已结束</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}

              <h2 className="sect">地点（客户端上报的 POI）</h2>
              {data.locations.length === 0 ? <div className="empty">未上报</div> : (
                <div>{data.locations.map((l) => <span className="badge" style={{ marginRight: 6 }} key={l}>{l}</span>)}</div>
              )}
            </>
          )}

          {tab === 'inventory' && (
            Object.entries(data.inventory).filter(([, n]) => n > 0).length === 0
              ? <div className="empty">背包是空的</div>
              : (
                <table className="grid" style={{ maxWidth: 420 }}>
                  <thead><tr><th>贴纸</th><th>id</th><th>数量</th></tr></thead>
                  <tbody>
                    {Object.entries(data.inventory).filter(([, n]) => n > 0).map(([sid, n]) => (
                      <tr key={sid}>
                        <td style={{ fontSize: 22 }}>{STICKER_GLYPHS[sid] ?? '❔'}</td>
                        <td className="mono">{sid}</td>
                        <td className="num-cell">{n}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )
          )}
        </>
      )}
    </>
  );
}
