import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { apiPost, fmtTs, useApi } from '../api.ts';
import { MAX_FLOWERS, STAMP_GLYPHS, STAMPS_PER_FLOWER, TASK_TYPE_LABELS, type CharacterSummary, type Scene, type WorldDetail, type WorldProp } from '../types.ts';
import { AnimStatusBadge, Fallback, PageHead, RowLink, ShortId, Sprite, Stats } from '../components.tsx';
import { playerLabel } from './Worlds.tsx';

const TABS = [
  { key: 'characters', label: '角色' },
  { key: 'scenes', label: '场景' },
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

/** 存量角色/物件缺 sceneId 时归属的默认场景（与 server DEFAULT_SCENE 对齐）。 */
const DEFAULT_SCENE = 'village';

const MAP_COLORS = {
  poi: '#2e9e8f',
  portal: '#8b5cf6',
  character: '#3b82f6',
  fairy: '#ec4899',
  prop: '#f59e0b',
} as const;

/**
 * 场景俯视图：把场景的 gridTiles×gridTiles 网格画成 SVG，POI/传送门/角色/物品
 * 按 tile 坐标叠上去。POI/传送门画半径圈，角色/物品是点；每个标记 <title> 悬停显详情。
 * tile (0,0) 在左上角，tileX→x、tileY→y（与客户端一致）。
 */
function SceneMap({ scene, characters, props }: { scene: Scene; characters: CharacterSummary[]; props: WorldProp[] }) {
  const n = scene.gridTiles;
  const dot = Math.max(0.7, n / 55); // 点半径（tile 单位）
  const sw = Math.max(0.12, n / 320); // 线宽
  const step = n > 40 ? 10 : 5; // 网格线间隔
  const lines: number[] = [];
  for (let i = step; i < n; i += step) lines.push(i);

  return (
    <svg viewBox={`0 0 ${n} ${n}`} width="100%" style={{ maxWidth: 520, aspectRatio: '1 / 1', background: '#faf8f3', border: '1px solid rgba(0,0,0,0.15)', borderRadius: 6, display: 'block' }}>
      {/* 网格 */}
      {lines.map((i) => (
        <g key={`l${i}`} stroke="rgba(0,0,0,0.07)" strokeWidth={sw}>
          <line x1={i} y1={0} x2={i} y2={n} />
          <line x1={0} y1={i} x2={n} y2={i} />
        </g>
      ))}

      {/* 传送门：半径圈 + 菱形标记 + 通往落点的虚线（落点在本场景时） */}
      {scene.portals.map((pt, i) => {
        const [x, y] = pt.tile;
        const [tx, ty] = pt.toTile;
        const m = dot * 1.3;
        return (
          <g key={`portal${i}`}>
            <title>{`传送门 → ${pt.toScene} (${tx},${ty})\n位置 (${x},${y}) 半径 ${pt.radius}`}</title>
            <circle cx={x} cy={y} r={pt.radius} fill={MAP_COLORS.portal} fillOpacity={0.1} stroke={MAP_COLORS.portal} strokeOpacity={0.5} strokeWidth={sw} />
            <line x1={x} y1={y} x2={tx} y2={ty} stroke={MAP_COLORS.portal} strokeWidth={sw} strokeDasharray={`${dot} ${dot}`} strokeOpacity={0.6} />
            <rect x={x - m} y={y - m} width={m * 2} height={m * 2} fill={MAP_COLORS.portal} transform={`rotate(45 ${x} ${y})`} />
          </g>
        );
      })}

      {/* POI：半径圈 + 中心点 + 名字 */}
      {scene.pois.map((p, i) => {
        const [x, y] = p.tile;
        return (
          <g key={`poi${i}`}>
            <title>{`${p.name}${p.aliases.length ? `（${p.aliases.join('、')}）` : ''}\n位置 (${x},${y}) 半径 ${p.radius}${p.trigger ? `\ntrigger: ${p.trigger}` : ''}`}</title>
            <circle cx={x} cy={y} r={p.radius} fill={MAP_COLORS.poi} fillOpacity={0.12} stroke={MAP_COLORS.poi} strokeOpacity={0.6} strokeWidth={sw} />
            <circle cx={x} cy={y} r={dot} fill={MAP_COLORS.poi} />
            <text x={x + dot * 1.4} y={y + dot * 0.8} fontSize={Math.max(1.8, n / 28)} fill="#333">{p.name}</text>
          </g>
        );
      })}

      {/* 物品（仅摆放中、有坐标） */}
      {props.map((pr) => {
        if (!pr.tile) return null;
        const [x, y] = pr.tile;
        const r = dot * 0.9;
        return (
          <g key={`prop${pr.id}`}>
            <title>{`物品：${String(pr.spec.name ?? '（未命名）')}\n位置 (${x},${y})`}</title>
            <rect x={x - r} y={y - r} width={r * 2} height={r * 2} fill={MAP_COLORS.prop} stroke="#fff" strokeWidth={sw} />
          </g>
        );
      })}

      {/* 角色（仙子跨场景，全场景都画） */}
      {characters.map((c) => {
        const { tileX: x, tileY: y } = c.position;
        return (
          <g key={`char${c.id}`}>
            <title>{`${c.name}${c.isFairy ? '（仙）' : ''}\n位置 (${x},${y}) 状态 ${c.state}`}</title>
            <circle cx={x} cy={y} r={dot * 1.05} fill={c.isFairy ? MAP_COLORS.fairy : MAP_COLORS.character} stroke="#fff" strokeWidth={sw} />
          </g>
        );
      })}
    </svg>
  );
}

function MapLegend() {
  const items: [string, string][] = [
    [MAP_COLORS.poi, '地点 POI'],
    [MAP_COLORS.portal, '传送门'],
    [MAP_COLORS.character, '角色'],
    [MAP_COLORS.fairy, '仙子'],
    [MAP_COLORS.prop, '物品'],
  ];
  return (
    <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap', margin: '6px 0 10px', fontSize: 12 }}>
      {items.map(([color, label]) => (
        <span key={label} style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
          <span style={{ width: 10, height: 10, borderRadius: 2, background: color, display: 'inline-block' }} />
          {label}
        </span>
      ))}
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
        scenes: data.scenes.length,
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
              { label: '场景', num: data.sceneCount },
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

          {tab === 'scenes' && (
            data.scenes.length === 0 ? <div className="empty">还没有场景（客户端未上传过地形/场景定义）</div> : (
              <>
                {data.scenes.map((s) => {
                  // 角色按场景归位（仙子跨场景，全场景都画）；物品同理，仅摆放中的有坐标
                  const chars = data.characters.filter((c) => c.isFairy || c.sceneId === s.sceneId);
                  const scProps = data.props.filter((p) => p.state === 'placed' && p.tile && (p.sceneId ?? DEFAULT_SCENE) === s.sceneId);
                  return (
                    <div className="panel" key={s.sceneId} style={{ marginBottom: 16 }}>
                      <h2 className="sect" style={{ marginTop: 0 }}>
                        {s.name} <span className="aux mono">{s.sceneId}</span>
                      </h2>
                      <dl className="kv">
                        <dt>地形资产</dt><dd><ShortId id={s.terrainAsset} /></dd>
                        <dt>网格</dt><dd className="mono">{s.gridTiles}×{s.gridTiles}</dd>
                        <dt>标记</dt><dd className="mono">POI {s.pois.length} · 传送门 {s.portals.length} · 角色 {chars.length} · 物品 {scProps.length}</dd>
                      </dl>
                      <MapLegend />
                      <SceneMap scene={s} characters={chars} props={scProps} />

                      <details style={{ marginTop: 10 }}>
                        <summary className="mono" style={{ cursor: 'pointer' }}>展开明细表</summary>
                        <h3 className="sect" style={{ fontSize: 14 }}>地点（POI · {s.pois.length}）</h3>
                        {s.pois.length === 0 ? <div className="empty">无 POI</div> : (
                          <table className="grid">
                            <thead><tr><th>名字</th><th>位置</th><th>半径</th><th>trigger</th><th>别名</th></tr></thead>
                            <tbody>
                              {s.pois.map((p, i) => (
                                <tr key={`${p.name}-${i}`}>
                                  <td><b>{p.name}</b></td>
                                  <td className="mono">({p.tile[0]},{p.tile[1]})</td>
                                  <td className="num-cell">{p.radius}</td>
                                  <td className="mono">{p.trigger || '—'}</td>
                                  <td>{p.aliases.length === 0 ? <span className="empty-cell">—</span> : p.aliases.map((a) => <span className="badge" style={{ marginRight: 4 }} key={a}>{a}</span>)}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}

                        <h3 className="sect" style={{ fontSize: 14 }}>传送门（Portal · {s.portals.length}）</h3>
                        {s.portals.length === 0 ? <div className="empty">无传送门</div> : (
                          <table className="grid">
                            <thead><tr><th>位置</th><th>半径</th><th>通往场景</th><th>落点</th></tr></thead>
                            <tbody>
                              {s.portals.map((pt, i) => (
                                <tr key={`${pt.toScene}-${i}`}>
                                  <td className="mono">({pt.tile[0]},{pt.tile[1]})</td>
                                  <td className="num-cell">{pt.radius}</td>
                                  <td><span className="badge seal">{pt.toScene}</span></td>
                                  <td className="mono">({pt.toTile[0]},{pt.toTile[1]})</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}
                      </details>
                    </div>
                  );
                })}
              </>
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

              <h2 className="sect">地点名（喂意图 LLM 的归一名单）</h2>
              <p className="aux" style={{ margin: '2px 0 8px' }}>权威来自服务端场景 POI（见「场景」标签页）；无场景时回退到客户端上报的名单。</p>
              {data.locations.length === 0 ? <div className="empty">暂无</div> : (
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
