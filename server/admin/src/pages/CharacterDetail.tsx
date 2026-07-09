import { Link, useParams } from 'react-router-dom';
import { assetUrl, fmtTs, useApi } from '../api.ts';
import { MEMORY_KIND_LABELS, type CharacterDetail, type MemoryItem } from '../types.ts';
import { AnimGenerateButton, AnimStatusBadge, Fallback, PageHead, ShortId, Sprite } from '../components.tsx';

function groupByKind(items: MemoryItem[]): [string, MemoryItem[]][] {
  const by = new Map<string, MemoryItem[]>();
  for (const m of items) {
    const arr = by.get(m.kind) ?? [];
    arr.push(m);
    by.set(m.kind, arr);
  }
  return [...by.entries()];
}

export function CharacterDetailPage() {
  const { id = '', cid = '' } = useParams();
  const { data, error, loading, reload } = useApi<CharacterDetail>(
    `/debug/api/worlds/${encodeURIComponent(id)}/characters/${encodeURIComponent(cid)}`,
  );
  const c = data?.character;
  return (
    <>
      <PageHead
        crumbs={<><Link to="/worlds">世界</Link> / <Link to={`/worlds/${id}`}>{id}</Link> / {c?.name || cid}</>}
        title={c ? <>{c.name}{c.isFairy && <span className="badge seal" style={{ marginLeft: 10, verticalAlign: 'middle' }}>小神仙</span>}</> : '角色详情'}
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && c && (
        <>
          <div className="panel panel-row">
            <div>
              <Sprite hash={c.appearance.spriteAsset} large alt={c.name} />
              <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <AnimStatusBadge status={data.spriteAnim.status} />
                {data.spriteAnim.status === 'ready' && data.spriteAnim.animAsset && (
                  <a className="mono" href={assetUrl(data.spriteAnim.animAsset)} target="_blank" rel="noreferrer">
                    图集 {data.spriteAnim.meta ? `${data.spriteAnim.meta.frameCount}帧@${data.spriteAnim.meta.fps}fps` : ''}
                  </a>
                )}
                <AnimGenerateButton spriteHash={c.appearance.spriteAsset} status={data.spriteAnim.status} onChanged={reload} />
              </div>
            </div>
            <dl className="kv" style={{ flex: 1, minWidth: 280 }}>
              <dt>id</dt><dd className="mono">{c.id}</dd>
              <dt>状态</dt><dd><span className="badge">{c.state}</span></dd>
              <dt>位置</dt><dd className="mono">({c.position.tileX}, {c.position.tileY})</dd>
              <dt>性格</dt><dd>{c.personality}</dd>
              <dt>音色</dt><dd className="mono">{c.voiceId}</dd>
              <dt>招呼风格</dt><dd>{c.greetingStyle || <span className="empty-cell">默认（按 id 哈希）</span>}</dd>
              <dt>能力</dt><dd>{c.abilities.map((a) => <span className="badge" style={{ marginRight: 4 }} key={a}>{a}</span>)}</dd>
              <dt>外观描述</dt><dd>{c.appearance.visualDescription || '—'}</dd>
              <dt>缩放</dt><dd className="mono">{c.appearance.scale}</dd>
              <dt>立绘资产</dt><dd className="mono">{c.appearance.spriteAsset || '—'}</dd>
            </dl>
          </div>

          <h2 className="sect">记忆（{data.memories.length}）</h2>
          {data.memories.length === 0 ? <div className="empty">还没有记忆</div> : groupByKind(data.memories).map(([kind, items]) => (
            <div className="panel" style={{ marginBottom: 10 }} key={kind}>
              <div style={{ marginBottom: 4 }}><span className="badge seal">{MEMORY_KIND_LABELS[kind] ?? kind}</span> <span className="mono">×{items.length}</span></div>
              {items.map((m, i) => (
                <div className="mem" key={i}>
                  <span>{m.text}</span>
                  {m.aboutPlayer && <Link className="mono" to={`/players/${m.aboutPlayer}`} style={{ marginLeft: 'auto' }}>@<ShortId id={m.aboutPlayer} /></Link>}
                  <span className="mono" style={m.aboutPlayer ? {} : { marginLeft: 'auto' }}>{m.ts ? fmtTs(m.ts) : ''}</span>
                </div>
              ))}
            </div>
          ))}

          <h2 className="sect">近期对话（{data.chatTurns.length}）</h2>
          {data.chatTurns.length === 0 ? <div className="empty">还没有对话</div> : (
            <div className="panel">
              <div className="chat">
                {data.chatTurns.map((t, i) => (
                  <div className={`turn ${t.role}`} key={i}>
                    <span className="who">{t.role === 'child' ? '小朋友' : c.name.slice(0, 3)}</span>
                    <span className="bubble">{t.text}</span>
                    {t.playerId && <Link className="mono" to={`/players/${t.playerId}`}><ShortId id={t.playerId} /></Link>}
                  </div>
                ))}
              </div>
            </div>
          )}

          <h2 className="sect">行为脚本</h2>
          <pre className="code">{JSON.stringify(c.behaviorScript, null, 2)}</pre>

          {Object.keys(c.relationships).length > 0 && (
            <>
              <h2 className="sect">关系</h2>
              <pre className="code">{JSON.stringify(c.relationships, null, 2)}</pre>
            </>
          )}
        </>
      )}
    </>
  );
}
