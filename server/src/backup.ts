/**
 * 全量数据备份 / 恢复。
 *
 * 备份内容 = 持久卷里 <dataDir> 的全部：world.db（一致性快照）+ 内容寻址资产 + 两份清单 + manifest。
 * **不含**语音模型（VOICE_MODELS_DIR，736M）——容器启动脚本 fetch-voice-models.sh 幂等重下，
 * 备它纯属浪费卷空间和带宽。
 *
 * 打包用系统 tar（运行镜像 node:26-slim 自带 GNU tar 1.35 + gzip；本地 macOS 是兼容的 bsdtar），
 * 而不是引 npm tar 包：真流式（tar 的 stdout 直接管给 HTTP 响应，包不进内存）、产物是老板能自己
 * 解开检查的通用格式、零新依赖。项目里 sprite_sheet.ts 已有 spawn ffmpeg/cwebp 的先例。
 */
import { spawn } from 'node:child_process';
import {
  createWriteStream,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
} from 'node:fs';
import { dirname, join } from 'node:path';
import { PassThrough } from 'node:stream';
import { DatabaseSync } from 'node:sqlite';
import { BACKUP_VERSION, type BackupManifest, type WorldStore } from './persistence.ts';

/** 包里必须有的文件（缺任何一个都不是一个能恢复的备份 → 拒绝导入）。 */
const REQUIRED_ENTRIES = ['manifest.json', 'world.db', 'assets.json', 'sprite_anims.json'];

/** 导出时打进包的 staging 文件（assets/ 单独从 dataDir 取，见下）。 */
const STAGED_ENTRIES = REQUIRED_ENTRIES;

export interface BackupExport {
  stream: PassThrough;
  manifest: BackupManifest;
  filename: string;
}

/** `maliang-backup-20260711-183000.tar.gz` —— 落到老板下载目录里得一眼看出是什么、什么时候的。 */
function backupFilename(createdAt: number): string {
  const p = (n: number): string => String(n).padStart(2, '0');
  const d = new Date(createdAt);
  const stamp =
    `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}` +
    `-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
  return `maliang-backup-${stamp}.tar.gz`;
}

/**
 * staging / 临时目录一律开在 dataDir 的**兄弟**位置，两个原因缺一不可：
 * - 同卷：导入的最后一步是 rename 原子替换 dataDir，跨设备 rename 会 EXDEV 直接失败；
 * - 在 dataDir 外面：否则临时文件会被 assets 那一路 tar 自己打进包里。
 */
function tmpDirNear(dataDir: string, prefix: string): string {
  return mkdtempSync(join(dirname(dataDir), prefix));
}

/**
 * 开一份全量备份：先在 staging 里做出一致性快照（见 WorldStore.exportSnapshot），
 * 再 spawn tar 把 staging + dataDir/assets 打成一个 gzip 流。
 *
 * 同步返回（stream 还在吐字节）——manifest 是快照那一刻的，可以立刻塞进响应头给管理台显示。
 * staging 在 tar 退出时清掉，成功失败都清。
 */
export function startBackup(store: WorldStore): BackupExport {
  const dataDir = store.dataDir;
  if (dataDir === null) throw new Error('backup requires a persistent data dir (MALIANG_DATA_DIR)');

  const staging = tmpDirNear(dataDir, '.maliang-backup-');
  let manifest: BackupManifest;
  try {
    manifest = store.exportSnapshot(staging);
  } catch (e) {
    rmSync(staging, { recursive: true, force: true });
    throw e;
  }

  // 两个 -C：清单与 db 快照取自 staging（自洽），assets/ 直接取自 dataDir。
  // assets 内容寻址、只增不改，所以边打包边有新资产写入也不会撕裂——最坏是新资产没进这一包。
  const child = spawn(
    'tar',
    ['-czf', '-', '-C', staging, ...STAGED_ENTRIES, '-C', dataDir, 'assets'],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );

  const out = new PassThrough();
  child.stdout.pipe(out);

  let stderr = '';
  child.stderr.on('data', (b: Buffer) => {
    stderr += b.toString();
  });
  child.on('error', (e) => {
    rmSync(staging, { recursive: true, force: true });
    out.destroy(e);
  });
  child.on('close', (code) => {
    rmSync(staging, { recursive: true, force: true });
    // tar 挂了要把响应也弄坏：否则下发的是一个静默截断的半截包，
    // 老板拿到手以为备份成功了，真出事那天才发现解不开。
    if (code !== 0) out.destroy(new Error(`tar exited ${code}: ${stderr.trim()}`));
  });

  return { stream: out, manifest, filename: backupFilename(manifest.createdAt) };
}

export interface RestoreResult {
  /** 导入的包里有什么（导入前从包内 manifest.json 读出来的）。 */
  manifest: BackupManifest;
  /** 被覆盖的旧数据另存成了哪个包——导入错了还能拿它回来。 */
  preRestoreBackup: string;
}

/** 保留最近几份 pre-restore 兜底包，多了删旧的（卷空间不是无限的）。 */
const PRE_RESTORE_KEEP = 3;

/**
 * 从 tar.gz 恢复全量数据（**破坏性**：当前 dataDir 会被整个换掉）。
 *
 * 顺序是刻意的，每一步都是为了让"导入失败"不至于把老板的现网数据也搭进去：
 *  1. 解到同卷临时目录并校验（版本 / 必需文件 / db 能不能打开）—— 包是坏的就在这里失败，
 *     此时现网数据一个字节都没动过。
 *  2. 把**当前**数据先备份成 pre-restore 包（导错了还有的救）。
 *  3. rename 原子换目录：dataDir → .old，解出来的 → dataDir。同卷才成立，见 tmpDirNear。
 *  4. store.reload() 让进程内状态跟上；reload 失败就把 .old 换回来，回到步骤 3 之前的状态。
 */
export async function restoreBackup(store: WorldStore, tarPath: string): Promise<RestoreResult> {
  const dataDir = store.dataDir;
  if (dataDir === null) throw new Error('restore requires a persistent data dir (MALIANG_DATA_DIR)');

  // ── 1. 解包 + 校验（还没碰现网数据）──
  const incoming = tmpDirNear(dataDir, '.maliang-restore-');
  let manifest: BackupManifest;
  try {
    await extractTar(tarPath, incoming);
    manifest = validateRestoreDir(incoming);
  } catch (e) {
    rmSync(incoming, { recursive: true, force: true });
    throw e;
  }

  // ── 2. 先把当前数据另存一份（唯一一次"导入前反悔"的机会）──
  const preRestoreBackup = await writeBackupToFile(store, dirname(dataDir));
  pruneOldPreRestores(dirname(dataDir));

  // ── 3. 原子换目录 ──
  const old = `${dataDir}.old-${Date.now()}`;
  renameSync(dataDir, old);
  try {
    renameSync(incoming, dataDir);
  } catch (e) {
    renameSync(old, dataDir); // 换不过去就换回来，现网数据原样还在
    rmSync(incoming, { recursive: true, force: true });
    throw e;
  }

  // ── 4. 进程内状态跟上新数据 ──
  try {
    store.reload();
  } catch (e) {
    rmSync(dataDir, { recursive: true, force: true });
    renameSync(old, dataDir);
    store.reload(); // 回到旧数据；这一步再炸就只能重启进程了，让它抛出去
    throw e;
  }

  rmSync(old, { recursive: true, force: true });
  return { manifest, preRestoreBackup };
}

/** 把包解到 destDir。tar 非零退出 = 包坏了/不是 gzip/被截断，直接抛。 */
function extractTar(tarPath: string, destDir: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn('tar', ['-xzf', tarPath, '-C', destDir], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.on('data', (b: Buffer) => {
      stderr += b.toString();
    });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`不是一个有效的备份包（tar 退出码 ${code}）：${stderr.trim()}`));
    });
  });
}

/**
 * 校验解出来的目录能不能当数据用。宁可在这里拒绝，也不要导进半套数据——
 * 这是灾难恢复现场，"尽力而为"地导入一半比干脆失败更糟。
 */
function validateRestoreDir(dir: string): BackupManifest {
  for (const f of REQUIRED_ENTRIES) {
    if (!existsSync(join(dir, f))) throw new Error(`备份包缺少 ${f}，不是一个完整的马良备份`);
  }
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as BackupManifest;
  if (manifest.version !== BACKUP_VERSION) {
    throw new Error(`备份包版本 ${manifest.version} 与当前服务端（${BACKUP_VERSION}）不一致，拒绝导入`);
  }
  // db 打得开、关键表在——挡住"tar 是好的但里面 world.db 是空文件/别的库"这类包。
  const db = new DatabaseSync(join(dir, 'world.db'), { readOnly: true });
  try {
    for (const t of ['players', 'worlds', 'characters']) {
      const row = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?")
        .get(t) as { name?: string } | undefined;
      if (!row?.name) throw new Error(`备份包里的 world.db 缺 ${t} 表，不是马良的库`);
    }
  } finally {
    db.close();
  }
  // 空库也得有 assets/（导出时保证会建），缺了说明包被人动过
  if (!existsSync(join(dir, 'assets'))) throw new Error('备份包缺少 assets/ 目录');
  return manifest;
}

/** 把一份全量备份直接落成文件（pre-restore 兜底包用；不走 HTTP，所以不用流给谁）。 */
function writeBackupToFile(store: WorldStore, destDir: string): Promise<string> {
  const { stream, filename } = startBackup(store);
  const out = join(destDir, `pre-restore-${filename}`);
  return new Promise((resolve, reject) => {
    const ws = createWriteStream(out);
    stream.pipe(ws);
    stream.on('error', reject);
    ws.on('error', reject);
    ws.on('finish', () => resolve(out));
  });
}

/** pre-restore 包只留最近 PRE_RESTORE_KEEP 份。 */
function pruneOldPreRestores(dir: string): void {
  const files = readdirSync(dir)
    .filter((f) => f.startsWith('pre-restore-maliang-backup-'))
    .sort()
    .reverse();
  for (const f of files.slice(PRE_RESTORE_KEEP)) rmSync(join(dir, f), { force: true });
}
