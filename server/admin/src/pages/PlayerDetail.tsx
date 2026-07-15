import { Link, useParams } from 'react-router-dom';
import { fmtTs, useApi } from '../api.ts';
import { MEMORY_KIND_LABELS, type PlayerDetail } from '../types.ts';
import { AnchorBadge, AnimGenerateButton, AnimStatusBadge, Fallback, PageHead, Sprite } from '../components.tsx';

export function PlayerDetailPage() {
  const { id = '' } = useParams();
  const { data, error, loading, reload } = useApi<PlayerDetail>(`/debug/api/players/${encodeURIComponent(id)}`);
  return (
    <>
      <PageHead
        crumbs={<><Link to="/players">玩家</Link> / {data?.player.name || id}</>}
        title={data ? (data.player.name || '（未命名）') : '玩家详情'}
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (
        <>
          <div className="panel panel-row">
            <div>
              <Sprite hash={data.player.spriteAsset} large alt={data.player.name} anchors={data.player.anchors} />
              {data.player.spriteAsset && (
                <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                  <AnchorBadge anchors={data.player.anchors} />
                  <AnimStatusBadge status={data.spriteAnim.status} />
                  <AnimGenerateButton spriteHash={data.player.spriteAsset} status={data.spriteAnim.status} onChanged={reload} />
                </div>
              )}
            </div>
            <dl className="kv" style={{ flex: 1, minWidth: 260 }}>
              <dt>id</dt><dd className="mono">{data.player.id}</dd>
              <dt>名字</dt><dd>{data.player.name || '—'}</dd>
              <dt>称呼</dt><dd>{data.player.nickname || '—'}</dd>
              <dt>性别</dt><dd>{data.player.gender === 'girl' ? '女孩' : data.player.gender === 'boy' ? '男孩' : data.player.gender || '—'}</dd>
              <dt>喜欢的颜色</dt><dd>{data.player.color || '—'}</dd>
              <dt>建档时间</dt><dd className="mono">{data.player.createdAt || '—'}</dd>
              <dt>形象资产</dt><dd className="mono">{data.player.spriteAsset || '—'}</dd>
              <dt>锚点</dt><dd className="mono">{data.player.anchors
                ? `头(${data.player.anchors.headTop.x.toFixed(2)},${data.player.anchors.headTop.y.toFixed(2)}) 左手(${data.player.anchors.handL.x.toFixed(2)},${data.player.anchors.handL.y.toFixed(2)}) 右手(${data.player.anchors.handR.x.toFixed(2)},${data.player.anchors.handR.y.toFixed(2)}) · ${data.player.anchors.source}`
                : '—'}</dd>
            </dl>
          </div>

          <h2 className="sect">创建形象档案（onboarding）</h2>
          {!data.onboarding ? <div className="empty">没有 onboarding 档案（老档案或还没走完新版创建流程）</div> : (
            <div className="panel">
              <dl className="kv">
                <dt>性别</dt><dd>{data.onboarding.attrs.gender || '—'}</dd>
                <dt>发型</dt><dd>{data.onboarding.attrs.hairstyle || '—'}</dd>
                <dt>衣服</dt><dd>{data.onboarding.attrs.outfit || '—'}</dd>
                <dt>主色</dt><dd>{data.onboarding.attrs.color || '—'}</dd>
                <dt>喜欢的图案</dt><dd>{data.onboarding.attrs.motifs.length > 0 ? data.onboarding.attrs.motifs.join('、') : '—'}</dd>
                <dt>配饰</dt><dd>{data.onboarding.attrs.accessory || '—'}</dd>
                <dt>开放语音原话</dt><dd>{data.onboarding.attrs.extras.length > 0 ? data.onboarding.attrs.extras.map((e, i) => <span className="badge" key={i} style={{ marginRight: 6 }}>{e}</span>) : '—'}</dd>
                <dt>照镜子修改</dt><dd>{data.onboarding.refineNotes.length > 0 ? data.onboarding.refineNotes.map((e, i) => <span className="badge pine" key={i} style={{ marginRight: 6 }}>{e}</span>) : '—'}</dd>
                <dt>最终外观描述</dt><dd>{data.onboarding.visualDescription || '—'}</dd>
              </dl>
            </div>
          )}

          <h2 className="sect">会话史（{data.visits.length}）</h2>
          {data.visits.length === 0 ? <div className="empty">还没来过</div> : (
            <table className="grid">
              <thead><tr><th>世界</th><th>开始</th><th>结束</th><th>时长</th><th>状态</th></tr></thead>
              <tbody>
                {[...data.visits].sort((a, b) => b.startedAt - a.startedAt).map((v) => (
                  <tr key={v.id}>
                    <td><Link to={`/worlds/${v.worldId}`}>{v.worldId}</Link></td>
                    <td className="mono">{fmtTs(v.startedAt)}</td>
                    <td className="mono">{fmtTs(v.endedAt)}</td>
                    <td className="num-cell">{v.endedAt ? `${Math.max(1, Math.round((v.endedAt - v.startedAt) / 60000))} 分钟` : '—'}</td>
                    <td>{v.endedAt === null ? <span className="badge pine">进行中</span> : <span className="badge">已结束</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}

          <h2 className="sect">角色对 TA 的记忆</h2>
          {data.memories.length === 0 ? <div className="empty">还没有角色记住 TA</div> : data.memories.map((g) => (
            <div className="panel" style={{ marginBottom: 10 }} key={g.characterId}>
              <div style={{ marginBottom: 6 }}>
                <Link to={`/worlds/${g.worldId}/characters/${g.characterId}`}><b>{g.characterName}</b></Link>
                <span className="mono" style={{ marginLeft: 8 }}>@{g.worldId}</span>
              </div>
              {g.items.map((m, i) => (
                <div className="mem" key={i}>
                  <span className="badge">{MEMORY_KIND_LABELS[m.kind] ?? m.kind}</span>
                  <span>{m.text}</span>
                  <span className="mono" style={{ marginLeft: 'auto' }}>{m.ts ? fmtTs(m.ts) : ''}</span>
                </div>
              ))}
            </div>
          ))}

          <h2 className="sect">与角色的对话</h2>
          {data.chats.length === 0 ? <div className="empty">还没有对话</div> : data.chats.map((g) => (
            <div className="panel" style={{ marginBottom: 10 }} key={g.characterId}>
              <div style={{ marginBottom: 8 }}>
                <Link to={`/worlds/${g.worldId}/characters/${g.characterId}`}><b>{g.characterName}</b></Link>
                <span className="mono" style={{ marginLeft: 8 }}>@{g.worldId} · {g.turns.length} 条</span>
              </div>
              <div className="chat">
                {g.turns.map((t, i) => (
                  <div className={`turn ${t.role}`} key={i}>
                    <span className="who">{t.role === 'child' ? '小朋友' : g.characterName.slice(0, 3)}</span>
                    <span className="bubble">{t.text}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </>
      )}
    </>
  );
}
