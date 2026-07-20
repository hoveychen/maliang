import { useEffect, useRef, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { ApiError, apiPost, assetUrl, getToken, setToken } from './api.ts';
import { CLIP_LABELS, type AnchorPoint, type CharacterAnchors, type ClipName, type ClipRange, type SpriteAnimMeta, type SpriteAnimRecord } from './types.ts';

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

/**
 * 图集帧动画播放器：canvas 按 meta 逐帧画 cell，fps 驱动循环。
 * 传 clip（{start,count}）只循环该段（idle / talking），不传则整张循环。
 * 画布按 cellW/cellH 比例定尺寸，避免非方形 cell 被拉扁。
 */
function SheetPlayer(props: { src: string; meta: SpriteAnimMeta; clip?: ClipRange; size?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const { src, meta, clip } = props;
  const size = props.size ?? 320;
  const first = clip?.start ?? 0;
  const count = clip?.count ?? meta.frameCount;
  const h = size;
  const w = Math.max(1, Math.round((size * meta.cellW) / meta.cellH));
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
      const local = count > 0 ? Math.floor(((t - start) / 1000) * meta.fps) % count : 0;
      const frame = first + local;
      const col = frame % meta.cols;
      const row = Math.floor(frame / meta.cols);
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.drawImage(img, col * meta.cellW, row * meta.cellH, meta.cellW, meta.cellH, 0, 0, canvas.width, canvas.height);
      raf = requestAnimationFrame(draw);
    };
    img.onload = () => { raf = requestAnimationFrame(draw); };
    return () => cancelAnimationFrame(raf);
  }, [src, meta, first, count, w, h]);
  return <canvas ref={ref} width={w} height={h} className="sprite-canvas" />;
}

/**
 * 图集分段循环预览：ready 的图集按 idle / talking 分别循环播放（各一个小画面）。
 * v2 多段图集读 meta.clips 拆段；v1 单段（无 clips）整张当 idle 播。
 */
export function ClipPreviews(props: { src: string; meta: SpriteAnimMeta; size?: number }) {
  const { src, meta } = props;
  const size = props.size ?? 160;
  const clips = meta.clips;
  const segs: { name: ClipName; clip?: ClipRange; count: number }[] = clips
    ? (['idle', 'talking'] as ClipName[])
        .filter((n) => clips[n] && clips[n]!.count > 0)
        .map((n) => ({ name: n, clip: clips[n], count: clips[n]!.count }))
    : [{ name: 'idle', clip: undefined, count: meta.frameCount }];
  if (segs.length === 0) return null;
  return (
    <div className="clip-previews" style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
      {segs.map((s) => (
        <figure key={s.name} style={{ margin: 0, textAlign: 'center' }}>
          <SheetPlayer src={src} meta={meta} clip={s.clip} size={size} />
          <figcaption className="mono" style={{ fontSize: 12, marginTop: 2 }}>
            {CLIP_LABELS[s.name]} · {s.count}帧@{meta.fps}fps
          </figcaption>
        </figure>
      ))}
    </div>
  );
}

/**
 * Seedance 原始视频：把生成时入库的绿幕原片（idle/moving/talking 各一段 mp4）内嵌 <video> 播放，
 * 并附「原片 mp4」链接在新标签打开/下载。绿底方便一眼看出是抠图前的绿幕原片。
 */
export function RawClipVideos(props: { clipVideos?: Partial<Record<ClipName, string>>; size?: number }) {
  const cv = props.clipVideos;
  if (!cv) return null;
  const size = props.size ?? 200;
  const segs = (['idle', 'moving', 'talking'] as ClipName[]).filter((n) => cv[n]);
  if (segs.length === 0) return null;
  return (
    <div style={{ display: 'flex', gap: 12, flexWrap: 'wrap' }}>
      {segs.map((n) => (
        <figure key={n} style={{ margin: 0, textAlign: 'center' }}>
          {/* eslint-disable-next-line jsx-a11y/media-has-caption -- 绿幕原片无字幕轨 */}
          <video src={assetUrl(cv[n]!)} controls loop muted playsInline width={size} style={{ borderRadius: 6, background: '#00b140' }} />
          <figcaption className="mono" style={{ fontSize: 12, marginTop: 2 }}>
            {CLIP_LABELS[n]} · <a href={assetUrl(cv[n]!)} target="_blank" rel="noreferrer">原片 mp4</a>
          </figcaption>
        </figure>
      ))}
    </div>
  );
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
              <ClipPreviews src={assetUrl(anim.animAsset)} meta={anim.meta} size={240} />
              <figcaption>循环动画</figcaption>
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
export function Sprite(props: { hash: string; large?: boolean; alt?: string; placeholder?: string; anchors?: CharacterAnchors }) {
  const [open, setOpen] = useState(false);
  const cls = props.large ? 'sprite-lg' : 'sprite-thumb';
  if (!props.hash) return <div className={`${cls} sprite-ph`}>{props.placeholder ?? '无立绘'}</div>;
  // 带锚点：按自然宽高比渲染（不塞进固定方框——object-fit:contain 的信箱边会让归一化点位错位），
  // 三个锚点按归一化坐标(原点左上)直接叠在立绘像素上。
  if (props.anchors) {
    return (
      <>
        <span className="sprite-wrap sprite-click" title="点击放大" onClick={(e) => { e.stopPropagation(); setOpen(true); }}>
          <img className="sprite-anchored" src={assetUrl(props.hash)} alt={props.alt ?? ''} loading="lazy" />
          <AnchorDots anchors={props.anchors} />
        </span>
        {open && <SpriteLightbox hash={props.hash} alt={props.alt ?? ''} onClose={() => setOpen(false)} />}
      </>
    );
  }
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

/** 立绘上叠三个贴纸锚点（头顶/左手/右手），归一化坐标 → 百分比定位；hover 看坐标。pointer-events:none 不挡点击放大。 */
function AnchorDots({ anchors }: { anchors: CharacterAnchors }) {
  const dots: { label: string; p: AnchorPoint; color: string }[] = [
    { label: '头顶', p: anchors.headTop, color: '#e8590c' },
    { label: '左手', p: anchors.handL, color: '#1c7ed6' },
    { label: '右手', p: anchors.handR, color: '#2f9e44' },
  ];
  return (
    <span className="anchor-dots">
      {dots.map((d) => (
        <span
          key={d.label}
          className="anchor-dot"
          style={{ left: `${d.p.x * 100}%`, top: `${d.p.y * 100}%`, background: d.color }}
          title={`${d.label} (${d.p.x.toFixed(3)}, ${d.p.y.toFixed(3)})`}
        />
      ))}
    </span>
  );
}

/** 锚点来源徽章（vision=真检测/兜底=alpha 现算/无=走客户端兜底），详情页立绘旁一眼看出成色。 */
export function AnchorBadge(props: { anchors?: CharacterAnchors }) {
  if (!props.anchors) return <span className="badge">无锚点（走客户端兜底）</span>;
  if (props.anchors.source === 'vision') return <span className="badge pine">锚点·vision</span>;
  return <span className="badge">锚点·兜底</span>;
}

/** 动画状态徽章（none/pending/ready/failed 统一样式，角色表/详情页共用）。 */
export function AnimStatusBadge(props: { status: string }) {
  if (props.status === 'ready') return <span className="badge pine">动画就绪</span>;
  if (props.status === 'pending') return <span className="badge">生成中</span>;
  if (props.status === 'failed') return <span className="badge seal">动画失败</span>;
  return <span className="badge">无动画</span>;
}

/** 体型档：从 scale 反推 小/中/大（明显档，与服务端 scaleToSize 同阈值 ≤0.85 小 / ≥1.2 大）。 */
export function sizeLabel(scale: number | null | undefined): string {
  if (typeof scale !== 'number' || !isFinite(scale)) return '';
  if (scale <= 0.85) return '小';
  if (scale >= 1.2) return '大';
  return '中';
}

/** 体型档徽标：小/中/大 + ×倍率。scale 缺失（如无 spec 的内置物品）显示 —。 */
export function SizeBadge(props: { scale: number | null | undefined }) {
  const s = props.scale;
  if (typeof s !== 'number' || !isFinite(s)) return <span className="empty-cell">—</span>;
  return <span className="badge">{sizeLabel(s)} ×{s}</span>;
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
