import { useMemo, useState } from 'react';
import { useApi } from '../api.ts';
import type { ItemDefWithIcon, ItemsResponse } from '../types.ts';
import { Fallback, PageHead, ShortId, SizeBadge, Sprite, Stats } from '../components.tsx';

/** 一张物品表：缩略图 + 字段。creations 段多一列来源世界。 */
function ItemTable(props: { rows: ItemDefWithIcon[]; showWorld?: boolean }) {
  if (props.rows.length === 0) return <div className="empty">没有物品</div>;
  return (
    <table className="grid">
      <thead>
        <tr>
          <th>外观</th><th>名字</th><th>渲染</th><th>占地</th><th>体型</th><th>阻挡</th>
          <th>游走</th><th>主题</th>{props.showWorld && <th>来源世界</th>}
          <th>被引用</th><th>id</th><th>spec</th>
        </tr>
      </thead>
      <tbody>
        {props.rows.map((it) => (
          <tr key={it.id}>
            <td><Sprite hash={it.iconHash} alt={it.name} placeholder="未渲染" /></td>
            <td><b>{it.name}</b></td>
            <td className="mono">{it.renderRef}{it.mount === 'edge' && <span className="badge"> 贴纸</span>}</td>
            <td className="mono">{it.footprintW}×{it.footprintH}</td>
            <td><SizeBadge scale={it.spec?.scale as number | undefined} /></td>
            <td>{it.blocking ? <span className="badge">占位</span> : <span className="badge pine">可穿行</span>}</td>
            <td className="num-cell">{it.wander || '—'}</td>
            <td className="mono">{it.themes?.length ? it.themes.join('、') : <span className="empty-cell">—</span>}</td>
            {props.showWorld && <td className="mono">{it.worldId ?? '—'}</td>}
            <td className="num-cell">{it.sceneRefs || <span className="empty-cell">0</span>}</td>
            <td><ShortId id={it.id} /></td>
            <td>
              {it.spec ? (
                <details>
                  <summary className="mono" style={{ cursor: 'pointer' }}>展开 spec</summary>
                  <pre className="code">{JSON.stringify(it.spec, null, 2)}</pre>
                </details>
              ) : <span className="empty-cell">—</span>}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function ItemsPage() {
  const { data, error, loading, reload } = useApi<ItemsResponse>('/debug/api/items');
  const [q, setQ] = useState('');
  const [onlyMissing, setOnlyMissing] = useState(false);

  const match = useMemo(() => {
    const kw = q.trim().toLowerCase();
    return (it: ItemDefWithIcon): boolean => {
      if (onlyMissing && it.iconHash) return false;
      if (!kw) return true;
      return (
        it.id.toLowerCase().includes(kw) ||
        it.name.toLowerCase().includes(kw) ||
        it.renderRef.toLowerCase().includes(kw) ||
        (it.themes ?? []).some((t) => t.toLowerCase().includes(kw))
      );
    };
  }, [q, onlyMissing]);

  const builtin = data?.builtin.filter(match) ?? [];
  const creations = data?.creations.filter(match) ?? [];

  return (
    <>
      <PageHead
        title="物品"
        count={data ? data.counts.builtin + data.counts.creations : undefined}
        desc="所有物品实体：内置定义（代码常量）+ 各世界语音造物。外观由客户端按 renderRef 渲染后上传缩略图。"
        right={<button className="plain" onClick={reload}>刷新</button>}
      />
      <Fallback loading={loading} error={error} onRetry={reload} />
      {data && (
        <>
          <Stats
            items={[
              { label: '内置', num: data.counts.builtin },
              { label: '造物', num: data.counts.creations },
              { label: '已有缩略图', num: data.counts.withIcon, accent: true },
              {
                label: '缺缩略图',
                num: data.counts.builtin + data.counts.creations - data.counts.withIcon,
              },
            ]}
          />
          <div className="toolbar">
            <input
              className="text-input"
              placeholder="按名字 / id / renderRef / 主题过滤"
              value={q}
              onChange={(e) => setQ(e.target.value)}
              style={{ flex: '0 1 320px' }}
            />
            <label style={{ display: 'flex', gap: 6, alignItems: 'center', cursor: 'pointer' }}>
              <input type="checkbox" checked={onlyMissing} onChange={(e) => setOnlyMissing(e.target.checked)} />
              只看缺缩略图
            </label>
          </div>

          <h2 className="sect">内置定义（items.ts BUILTIN_ITEMS，{builtin.length}/{data.counts.builtin}）</h2>
          <ItemTable rows={builtin} />

          <h2 className="sect">语音造物（各世界 items 表，{creations.length}/{data.counts.creations}）</h2>
          <ItemTable rows={creations} showWorld />
        </>
      )}
    </>
  );
}
