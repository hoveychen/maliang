import { useRef, useState } from 'react';
import { downloadBackup, fmtTs, uploadRestore } from '../api.ts';
import type { BackupManifest, RestoreResponse } from '../types.ts';
import { PageHead } from '../components.tsx';

function fmtSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** 包里有什么——导出后和导入后都用它把 manifest 摊开给老板看。 */
function ManifestTable(props: { m: BackupManifest }) {
  const c = props.m.counts;
  return (
    <table className="grid">
      <thead>
        <tr><th>玩家</th><th>世界</th><th>角色</th><th>造物</th><th>资产</th><th>动画</th><th>备份时刻</th></tr>
      </thead>
      <tbody>
        <tr>
          <td className="mono">{c.players}</td>
          <td className="mono">{c.worlds}</td>
          <td className="mono">{c.characters}</td>
          <td className="mono">{c.items}</td>
          <td className="mono">{c.assets}</td>
          <td className="mono">{c.spriteAnims}</td>
          <td className="mono">{fmtTs(props.m.createdAt)}</td>
        </tr>
      </tbody>
    </table>
  );
}

/**
 * 数据备份 / 恢复页。
 *
 * 服务端数据只有持久卷一个落点，卷没了就全没了——这一页是唯一的兜底。
 * 导入是破坏性的，所以刻意做成两步：选包 → 看清楚包里是什么 → 再点确认覆盖。
 */
export function DataPage() {
  const [exporting, setExporting] = useState(false);
  const [exported, setExported] = useState<BackupManifest | null>(null);
  const [exportErr, setExportErr] = useState('');

  const [file, setFile] = useState<File | null>(null);
  const [restoring, setRestoring] = useState(false);
  const [restored, setRestored] = useState<RestoreResponse | null>(null);
  const [restoreErr, setRestoreErr] = useState('');
  const fileInput = useRef<HTMLInputElement>(null);

  const doExport = async () => {
    setExporting(true);
    setExportErr('');
    try {
      setExported(await downloadBackup());
    } catch (e) {
      setExportErr(e instanceof Error ? e.message : String(e));
    } finally {
      setExporting(false);
    }
  };

  const doRestore = async () => {
    if (!file) return;
    // 第二道确认：上面已经让老板看过包名和体积，这里再拦一次——这一步之后数据就换掉了。
    if (!window.confirm(`确定用「${file.name}」覆盖服务器上的全部数据？\n\n当前数据会先自动另存一份兜底包，但仍请确认这是你要的那个备份。`)) {
      return;
    }
    setRestoring(true);
    setRestoreErr('');
    setRestored(null);
    try {
      setRestored(await uploadRestore(file));
      setFile(null);
      if (fileInput.current) fileInput.current.value = '';
    } catch (e) {
      setRestoreErr(e instanceof Error ? e.message : String(e));
    } finally {
      setRestoring(false);
    }
  };

  return (
    <>
      <PageHead
        title="数据"
        desc="全量备份与恢复。服务端数据只有持久卷一个落点——这里导出的包是唯一的兜底。"
      />

      <h2 className="sect">导出备份</h2>
      <div className="panel">
        <p className="page-desc">
          打包 <span className="mono">world.db</span>（玩家 / 世界 / 角色 / 记忆 / 对话 / 钱包）、
          全部内容寻址资产（立绘、idle 图集、地形、语音）以及两份清单，下载成一个{' '}
          <span className="mono">.tar.gz</span>。
          <br />
          <span className="aux">
            不含本地语音模型（736 MB，容器启动时会自己重新拉取，备份它纯属浪费）。
            数据库走 SQLite 的一致性快照，导出期间线上照常读写，不会拿到撕裂的数据。
          </span>
        </p>
        <div className="toolbar">
          <button className="plain" disabled={exporting} onClick={doExport}>
            {exporting ? '打包中…' : '导出全量备份'}
          </button>
          {exportErr && <span className="badge seal" title={exportErr}>导出失败</span>}
        </div>
        {exportErr && <div className="error-box">{exportErr}</div>}
        {exported && (
          <>
            <p className="page-desc">已下载。这一包里是：</p>
            <ManifestTable m={exported} />
          </>
        )}
      </div>

      <h2 className="sect">从备份恢复</h2>
      <div className="panel danger-panel">
        <p className="page-desc">
          <strong>破坏性操作</strong>：服务器上的<strong>全部</strong>数据会被这个包整个换掉，
          导入后所有小朋友的角色、记忆、小红花都以包里的为准。
          <br />
          <span className="aux">
            覆盖前服务端会自动把当前数据另存成一个 pre-restore 兜底包（留最近 3 份），导错了还能拿它回来。
            包坏了 / 版本不对会在覆盖之前就被拒绝，那种情况下现网数据一个字节都不会动。
          </span>
        </p>
        <div className="toolbar">
          <input
            ref={fileInput}
            type="file"
            accept=".gz,.tgz,application/gzip"
            onChange={(e) => {
              setFile(e.target.files?.[0] ?? null);
              setRestored(null);
              setRestoreErr('');
            }}
          />
        </div>
        {file && (
          <div className="toolbar">
            <span className="mono">{file.name}</span>
            <span className="aux">{fmtSize(file.size)}</span>
            <span className="spacer" />
            <button className="plain danger" disabled={restoring} onClick={doRestore}>
              {restoring ? '恢复中…' : '确认覆盖服务器数据'}
            </button>
          </div>
        )}
        {restoreErr && <div className="error-box">{restoreErr}</div>}
        {restored && (
          <>
            <p className="page-desc">
              恢复完成，服务端已切到新数据（无需重启）。导入的是：
            </p>
            <ManifestTable m={restored.manifest} />
            <p className="page-desc aux">
              覆盖前的数据已另存为 <span className="mono">{restored.preRestoreBackup}</span>
              （在服务器持久卷上）。
            </p>
          </>
        )}
      </div>
    </>
  );
}
