import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { ApiError, apiPost, assetUrl, getToken, setToken } from './api.ts';
import type { SpriteAnimMeta, SpriteAnimRecord } from './types.ts';

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

/** 图集帧动画播放器：canvas 按 meta 逐帧画 cell，fps 驱动循环。 */
function SheetPlayer(props: { src: string; meta: SpriteAnimMeta }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const { src, meta } = props;
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const img = new Image();
    img.src = src;
    let raf = 0;
    let start = 0;
    const draw = (t: number) => {
      if (!start) start = t;
      const frame = Math.floor(((t - start) / 1000) * meta.fps) % meta.frameCount;
      const col = frame % meta.cols;
      const row = Math.floor(frame / meta.cols);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, col * meta.cellW, row * meta.cellH, meta.cellW, meta.cellH, 0, 0, canvas.width, canvas.height);
      raf = requestAnimationFrame(draw);
    };
    img.onload = () => { raf = requestAnimationFrame(draw); };
    return () => cancelAnimationFrame(raf);
  }, [src, meta]);
  return <canvas ref={ref} width={320} height={320} className="sprite-canvas" />;
}

/** 立绘放大预览遮罩：左静态大图；/sprite-anim/:hash 就绪则右侧播 idle 动画。ESC/点遮罩关闭。 */
function SpriteLightbox(props: { hash: string; alt: string; onClose: () => void }) {
  const [anim, setAnim] = useState<SpriteAnimRecord | null>(null);
  useEffect(() => {
    let alive = true;
    fetch(`/sprite-anim/${props.hash}`)
      .then((r) => r.json())
      .then((d: SpriteAnimRecord) => { if (alive) setAnim(d); })
      .catch(() => {});
    return () => { alive = false; };
  }, [props.hash]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') props.onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [props.onClose]);
  const ready = anim?.status === 'ready' && !!anim.animAsset && !!anim.meta;
  return (
    <div className="lightbox" onClick={(e) => { e.stopPropagation(); props.onClose(); }}>
      <div className="lightbox-body" onClick={(e) => e.stopPropagation()}>
        <div className="lightbox-row">
          <figure>
            <img src={assetUrl(props.hash)} alt={props.alt} />
            <figcaption>静态立绘</figcaption>
          </figure>
          {ready && anim.animAsset && anim.meta && (
            <figure>
              <SheetPlayer src={assetUrl(anim.animAsset)} meta={anim.meta} />
              <figcaption>idle 动画 · {anim.meta.frameCount} 帧 @{anim.meta.fps}fps</figcaption>
            </figure>
          )}
        </div>
        <div className="lightbox-foot">
          <span className="mono">{props.hash}</span>
          {anim && !ready && (
            <span className="badge">
              {anim.status === 'none' ? '无动画' : anim.status === 'pending' ? '动画生成中' : '动画失败'}
            </span>
          )}
          <button className="plain" onClick={props.onClose}>关闭</button>
        </div>
      </div>
    </div>
  );
}

/** 立绘/物品缩略图：无资产给占位格；有资产可点击放大（含 idle 动画预览）。 */
export function Sprite(props: { hash: string; large?: boolean; alt?: string; placeholder?: string }) {
  const [open, setOpen] = useState(false);
  const cls = props.large ? 'sprite-lg' : 'sprite-thumb';
  if (!props.hash) return <div className={`${cls} sprite-ph`}>{props.placeholder ?? '无立绘'}</div>;
  return (
    <>
      <img
        className={`${cls} sprite-click`}
        src={assetUrl(props.hash)}
        alt={props.alt ?? ''}
        loading="lazy"
        title="点击放大"
        onClick={(e) => { e.stopPropagation(); setOpen(true); }}
      />
      {open && <SpriteLightbox hash={props.hash} alt={props.alt ?? ''} onClose={() => setOpen(false)} />}
    </>
  );
}

/** 动画状态徽章（none/pending/ready/failed 统一样式，角色表/详情页共用）。 */
export function AnimStatusBadge(props: { status: string }) {
  if (props.status === 'ready') return <span className="badge pine">动画就绪</span>;
  if (props.status === 'pending') return <span className="badge">生成中</span>;
  if (props.status === 'failed') return <span className="badge seal">动画失败</span>;
  return <span className="badge">无动画</span>;
}

/**
 * 补动画按钮：调 POST /admin/sprite-anim/:hash/generate 线上生成（已 ready 走 force 且先确认——烧钱）。
 * pending 期间禁用并每 5s 自动 onChanged 轮询刷新，直到 ready/failed。
 */
export function AnimGenerateButton(props: { spriteHash: string; status: string; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const pending = props.status === 'pending';
  const { onChanged } = props;
  useEffect(() => {
    if (!pending) return;
    const t = setInterval(onChanged, 5000);
    return () => clearInterval(t);
  }, [pending, onChanged]);
  if (!props.spriteHash) return null;
  const trigger = async () => {
    if (props.status === 'ready' && !window.confirm('已有动画。重新生成会调视频模型（约 $0.05/次），确定？')) return;
    setBusy(true);
    setErr('');
    try {
      await apiPost(`/admin/sprite-anim/${props.spriteHash}/generate${props.status === 'ready' ? '?force=true' : ''}`);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <>
      <button className="plain" disabled={busy || pending} onClick={trigger}>
        {pending ? '生成中…' : props.status === 'ready' ? '重新生成动画' : '补生成动画'}
      </button>
      {err && <span className="badge seal" title={err}>触发失败</span>}
    </>
  );
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
