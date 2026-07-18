import type { ReactNode } from 'react';
import { Link, useParams } from 'react-router-dom';
import { assetUrl, fmtTs, useApi } from '../api.ts';
import { MEMORY_KIND_LABELS, type CharacterDetail, type MemoryItem } from '../types.ts';
import { AnchorBadge, AnimGenerateButton, AnimStatusBadge, ClipPreviews, Fallback, PageHead, ShortId, SizeBadge, Sprite } from '../components.tsx';

function groupByKind(items: MemoryItem[]): [string, MemoryItem[]][] {
  const by = new Map<string, MemoryItem[]>();
  for (const m of items) {
    const arr = by.get(m.kind) ?? [];
    arr.push(m);
    by.set(m.kind, arr);
  }
  return [...by.entries()];
}

/** 按玩家分组：每个玩家一组，匿名/未绑定桶（player_id 为空）排最后。 */
function groupByPlayer<T>(items: T[], keyOf: (x: T) => string | undefined): [string, T[]][] {
  const by = new Map<string, T[]>();
  for (const it of items) {
    const k = keyOf(it) ?? '';
    const arr = by.get(k) ?? [];
    arr.push(it);
    by.set(k, arr);
  }
  return [...by.entries()].sort((a, b) => (a[0] === '' ? 1 : b[0] === '' ? -1 : 0));
}

/** 玩家分组表头：具名玩家给可点链接，匿名桶给徽章说明。 */
function PlayerGroupHead({ id, count }: { id: string; count: number }): ReactNode {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6, paddingBottom: 4, borderBottom: '1px solid var(--line, #e5e0d5)' }}>
      {id
        ? <Link className="mono" to={`/players/${id}`}>玩家 @<ShortId id={id} /></Link>
        : <span className="badge" title="没有玩家 id 的历史遗留数据（老客户端/迁移产生），对所有玩家可见">匿名 / 未绑定玩家</span>}
      <span className="mono" style={{ color: 'var(--dim, #999)' }}>×{count}</span>
    </div>
  );
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
              <Sprite hash={c.appearance.spriteAsset} large alt={c.name} anchors={c.appearance.anchors} />
              <div style={{ marginTop: 8, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                <AnchorBadge anchors={c.appearance.anchors} />
                <AnimStatusBadge status={data.spriteAnim.status} />
                {data.spriteAnim.status === 'ready' && data.spriteAnim.animAsset && (
                  <a className="mono" href={assetUrl(data.spriteAnim.animAsset)} target="_blank" rel="noreferrer">
                    图集 {data.spriteAnim.meta ? `${data.spriteAnim.meta.frameCount}帧@${data.spriteAnim.meta.fps}fps` : ''}
                  </a>
                )}
                <AnimGenerateButton spriteHash={c.appearance.spriteAsset} status={data.spriteAnim.status} onChanged={reload} />
              </div>
              {data.spriteAnim.status === 'ready' && data.spriteAnim.animAsset && data.spriteAnim.meta && (
                <div style={{ marginTop: 10 }}>
                  <ClipPreviews src={assetUrl(data.spriteAnim.animAsset)} meta={data.spriteAnim.meta} size={150} />
                </div>
              )}
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
              <dt>体型</dt><dd><SizeBadge scale={c.appearance.scale} /></dd>
              <dt>立绘资产</dt><dd className="mono">{c.appearance.spriteAsset || '—'}</dd>
              <dt>锚点</dt><dd className="mono">{c.appearance.anchors
                ? `头(${c.appearance.anchors.headTop.x.toFixed(2)},${c.appearance.anchors.headTop.y.toFixed(2)}) 左手(${c.appearance.anchors.handL.x.toFixed(2)},${c.appearance.anchors.handL.y.toFixed(2)}) 右手(${c.appearance.anchors.handR.x.toFixed(2)},${c.appearance.anchors.handR.y.toFixed(2)}) · ${c.appearance.anchors.source}`
                : '—'}</dd>
            </dl>
          </div>

          <h2 className="sect">记忆（{data.memories.length}）· 按玩家分开</h2>
          {data.memories.length === 0 ? <div className="empty">还没有记忆</div> : groupByPlayer(data.memories, (m) => m.aboutPlayer).map(([pid, mems]) => (
            <div className="panel" style={{ marginBottom: 10 }} key={pid || '__anon'}>
              <PlayerGroupHead id={pid} count={mems.length} />
              {groupByKind(mems).map(([kind, items]) => (
                <div style={{ marginBottom: 6 }} key={kind}>
                  <div style={{ marginBottom: 4 }}><span className="badge seal">{MEMORY_KIND_LABELS[kind] ?? kind}</span> <span className="mono">×{items.length}</span></div>
                  {items.map((m, i) => (
                    <div className="mem" key={i}>
                      <span>{m.text}</span>
                      <span className="mono" style={{ marginLeft: 'auto' }}>{m.ts ? fmtTs(m.ts) : ''}</span>
                    </div>
                  ))}
                </div>
              ))}
            </div>
          ))}

          <h2 className="sect">近期对话（{data.chatTurns.length}）· 按玩家分开</h2>
          {data.chatTurns.length === 0 ? <div className="empty">还没有对话</div> : groupByPlayer(data.chatTurns, (t) => t.playerId).map(([pid, turns]) => (
            <div className="panel" style={{ marginBottom: 10 }} key={pid || '__anon'}>
              <PlayerGroupHead id={pid} count={turns.length} />
              <div className="chat">
                {turns.map((t, i) => (
                  <div className={`turn ${t.role}`} key={i}>
                    <span className="who">{t.role === 'child' ? '小朋友' : c.name.slice(0, 3)}</span>
                    <span className="bubble">{t.text}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}

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
