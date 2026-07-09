import type { ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { ApiError, assetUrl, getToken, setToken } from './api.ts';

/** 页头：面包屑 + 宋体大标题 + 计数 + 说明。 */
export function PageHead(props: { crumbs?: ReactNode; title: ReactNode; count?: number; desc?: string; right?: ReactNode }) {
  return (
    <>
      {props.crumbs && <div className="crumbs">{props.crumbs}</div>}
      <div style={{ display: 'flex', alignItems: 'baseline' }}>
        <h1 className="page">
          {props.title}
          {props.count !== undefined && <span className="count">×{props.count}</span>}
        </h1>
        <div style={{ flex: 1 }} />
        {props.right}
      </div>
      {props.desc && <p className="page-desc">{props.desc}</p>}
    </>
  );
}

/** 加载/错误统一态。403 时给 token 输入框（?token= 忘带/失效的自救入口）。 */
export function Fallback(props: { loading: boolean; error: ApiError | null; onRetry: () => void }) {
  if (props.loading) return <div className="loading">加载中…</div>;
  if (!props.error) return null;
  if (props.error.status === 403) {
    return (
      <div className="error-box">
        <div style={{ marginBottom: 8 }}>需要管理 token（MALIANG_ADMIN_TOKEN）。</div>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            const v = new FormData(e.currentTarget).get('t');
            if (typeof v === 'string' && v.trim()) { setToken(v.trim()); props.onRetry(); }
          }}
        >
          <input name="t" placeholder="粘贴 admin token" defaultValue={getToken()} size={36} />
          <button className="plain" style={{ marginLeft: 8 }} type="submit">保存并重试</button>
        </form>
      </div>
    );
  }
  return (
    <div className="error-box">
      加载失败：{props.error.message}
      <button className="plain" style={{ marginLeft: 10 }} onClick={props.onRetry}>重试</button>
    </div>
  );
}

/** 立绘缩略图：无资产给占位格。 */
export function Sprite(props: { hash: string; large?: boolean; alt?: string }) {
  const cls = props.large ? 'sprite-lg' : 'sprite-thumb';
  if (!props.hash) return <div className={`${cls} sprite-ph`}>无立绘</div>;
  return <img className={cls} src={assetUrl(props.hash)} alt={props.alt ?? ''} loading="lazy" />;
}

/** 可点击整行跳转的 <tr>。 */
export function RowLink(props: { to: string; children: ReactNode }) {
  const nav = useNavigate();
  return (
    <tr className="rowlink" onClick={() => nav(props.to)}>
      {props.children}
    </tr>
  );
}

export function ShortId(props: { id: string | number }) {
  const s = String(props.id);
  return <span className="mono" title={s}>{s.length > 10 ? s.slice(0, 10) + '…' : s}</span>;
}

/** 统计牌行。 */
export function Stats(props: { items: { label: string; num: ReactNode; accent?: boolean }[] }) {
  return (
    <div className="stats">
      {props.items.map((s, i) => (
        <div className={`stat${s.accent ? ' accent' : ''}`} key={i}>
          <div className="num">{s.num}</div>
          <div className="lbl">{s.label}</div>
        </div>
      ))}
    </div>
  );
}
