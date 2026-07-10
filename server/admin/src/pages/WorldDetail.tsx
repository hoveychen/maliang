import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { apiPost, fmtTs, useApi } from '../api.ts';
import { MAX_FLOWERS, STAMP_GLYPHS, STAMPS_PER_FLOWER, TASK_TYPE_LABELS, type WorldDetail } from '../types.ts';
import { AnimStatusBadge, Fallback, PageHead, RowLink, ShortId, Sprite, Stats } from '../components.tsx';
import { playerLabel } from './Worlds.tsx';

const TABS = [
  { key: 'characters', label: '角色' },
  { key: 'props', label: '物品' },
  { key: 'events', label: '世界事件' },
  { key: 'wallet', label: '小红花钱包' },
] as const;

/** 手写剧本（Plan 2 上线前的试演入口，见 server/src/screenplays/）。 */
const SCREENPLAYS = [
  { key: 'hide_and_seek', label: '躲猫猫', hint: '要世界里有在线的小朋友：村民当鬼来追他' },
  { key: 'three_act_play', label: '三幕小剧场', hint: '要三个村民：演《丑小鸭》，孩子在场看戏' },
] as const;

/** 开演面板：点一下就在这个世界起一场戏，进世界的平板会立刻进观演态。 */
function DebutPanel({ worldId }: { worldId: string }) {
  const [busy, setBusy] = useState('');
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const start = async (key: string, label: string) => {
    setBusy(key);
    setMsg(null);
    try {
      const r = await apiPost<{ actors: { name: string }[] }>(`/admin/worlds/${encodeURIComponent(worldId)}/stage`, { screenplay: key });
      setMsg({ ok: true, text: `《${label}》开演了：${r.actors.map((a) => a.name).join('、')}` });
    } catch (e) {
      setMsg({ ok: false, text: e instanceof Error ? e.message : String(e) });
    } finally {
      setBusy('');
    }
  };

  return (
    <div className="panel" style={{ marginBottom: 16 }}>
      <h2 className="sect" style={{ marginTop: 0 }}>试演</h2>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        {SCREENPLAYS.map((s) => (
          <button key={s.key} title={s.hint} disabled={busy !== ''} onClick={() => void start(s.key, s.label)}>
            {busy === s.key ? '开演中…' : `开演 · ${s.label}`}
          </button>
        ))}
        {msg && <span className={msg.ok ? 'badge pine' : 'badge seal'}>{msg.text}</span>}
      </div>
    </div>
  );
}

export function WorldDetailPage() {
  const { id = '' } = useParams();
  const [sp, setSp] = useSearchParams();
  const tab = sp.get('tab') ?? 'characters';
  const { data, error, loading, reload } = useApi<WorldDetail>(`/debug/api/worlds/${encodeURIComponent(id)}`);

  const counts: Record<string, number> = data
    ? {
        characters: data.characters.length,
        props: data.props.length,
        events: data.visits.length + data.activeTasks.length,
        wallet: data.wallets.length,
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
          <DebutPanel worldId={id} />
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
                  <tr><th>立绘</th><th>名字</th><th>动画</th><th>状态</th><th>位置</th><th>性格</th><th>记忆</th><th>对话</th><th>音色</th><th>id</th></tr>
                </thead>
                <tbody>
                  {data.characters.map((c) => (
                    <RowLink to={`/worlds/${id}/characters/${c.id}`} key={c.id}>
                      <td><Sprite hash={c.spriteAsset} alt={c.name} /></td>
                      <td><b>{c.name}</b>{c.isFairy && <span className="badge seal" style={{ marginLeft: 6 }}>仙</span>}</td>
                      <td><AnimStatusBadge status={c.spriteAnimStatus} /></td>
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
              <h2 className="sect" style={{ marginTop: 4 }}>进行中委托（按玩家）</h2>
              {data.activeTasks.length === 0 ? <div className="empty">当前没有进行中的委托</div> : data.activeTasks.map(({ playerId, task }) => (
                <div className="panel" key={playerId} style={{ marginBottom: 8 }}>
                  <dl className="kv">
                    <dt>玩家</dt><dd>{playerLabel(playerId)}</dd>
                    <dt>类型</dt><dd><span className="badge seal">{TASK_TYPE_LABELS[task.type] ?? task.type}</span></dd>
                    <dt>委托人</dt><dd>{task.npcName} <ShortId id={task.npcId} /></dd>
                    {task.targetName && <><dt>对象</dt><dd>{task.targetName}</dd></>}
                    {task.locationName && <><dt>地点</dt><dd>{task.locationName}</dd></>}
                    {task.message && <><dt>要带的话</dt><dd>{task.message}</dd></>}
                    <dt>完成盖章</dt><dd>{STAMP_GLYPHS[task.stampStyle] ?? '❔'} {task.stampStyle}</dd>
                  </dl>
                </div>
              ))}

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

          {tab === 'wallet' && (
            data.wallets.length === 0 ? <div className="empty">还没有玩家领过钱包（首次读取时发初始小红花）</div> : (
              <table className="grid" style={{ maxWidth: 560 }}>
                <thead>
                  <tr><th>玩家</th><th>🌸 小红花</th><th>未结算盖章</th><th>累计盖章</th></tr>
                </thead>
                <tbody>
                  {data.wallets.map(({ playerId, wallet }) => (
                    <tr key={playerId}>
                      <td>{playerLabel(playerId)}</td>
                      <td className="num-cell"><b>{wallet.flowers}</b><span className="aux">/{MAX_FLOWERS}</span></td>
                      <td className="num-cell">{wallet.stampProgress}<span className="aux">/{STAMPS_PER_FLOWER}</span></td>
                      <td className="num-cell">{wallet.stampsTotal}</td>
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
