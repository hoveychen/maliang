/**
 * 全量备份 / 恢复。
 *
 * 这里的验收标准刻意定成「包能不能真的解开、解开的数据能不能真的用」——
 * 而不是「端点返回 200」。备份是灾难恢复的唯一兜底，一个"看起来成功"但解不开的包
 * 比没有备份更危险：老板会以为自己有备份。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { WorldStore, BACKUP_VERSION, type BackupManifest } from '../src/persistence.ts';
import { startBackup, restoreBackup } from '../src/backup.ts';
import { buildServer } from '../src/server.ts';
import type { FastifyInstance } from 'fastify';

const TOKEN = 'test-admin-token';

/** 造一个有真实内容的 store：一个世界 + 一个角色 + 一张立绘资产。 */
function seedStore(dataDir: string): { store: WorldStore; spriteHash: string } {
  const store = new WorldStore(dataDir);
  store.createWorld('w1');
  const spriteHash = store.putAsset({ bytes: new Uint8Array([1, 2, 3, 4, 5]), mime: 'image/png' });
  store.addCharacter({
    id: 'c1',
    worldId: 'w1',
    name: '花环小鹿',
    persona: '爱笑',
    voiceId: 'v1',
    appearance: { spriteAsset: spriteHash },
  } as never);
  store.setSpriteAnimReady(spriteHash, 'anim1', {
    cols: 6, rows: 6, frameCount: 31, fps: 8, cellW: 100, cellH: 100, width: 600, height: 600,
  });
  return { store, spriteHash };
}

/** 把备份流收成一个 .tar.gz 文件，返回路径。 */
async function backupToFile(store: WorldStore, dest: string): Promise<BackupManifest> {
  const { stream, manifest } = startBackup(store);
  const chunks: Buffer[] = [];
  for await (const c of stream) chunks.push(c as Buffer);
  writeFileSync(dest, Buffer.concat(chunks));
  return manifest;
}

describe('全量备份导出', () => {
  let root: string;
  before(() => {
    root = mkdtempSync(join(tmpdir(), 'maliang-bk-'));
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  it('导出的包能被 tar 解开，且四件套 + 资产都在里面', async () => {
    const { store, spriteHash } = seedStore(join(root, 'export', 'data'));
    const tgz = join(root, 'out.tar.gz');
    const manifest = await backupToFile(store, tgz);

    const listing = execFileSync('tar', ['-tzf', tgz], { encoding: 'utf8' }).split('\n');
    for (const f of ['manifest.json', 'world.db', 'assets.json', 'sprite_anims.json']) {
      assert.ok(listing.includes(f), `包里缺 ${f}：${listing.join(' ')}`);
    }
    // 资产是内容寻址的裸文件，必须逐个躺在 assets/ 下
    assert.ok(
      listing.some((l) => l === `assets/${spriteHash}`),
      `包里缺立绘资产 assets/${spriteHash}`,
    );
    assert.equal(manifest.version, BACKUP_VERSION);
    assert.equal(manifest.counts.characters, 1);
    assert.equal(manifest.counts.assets, 1);
  });

  it('world.db 是一致性快照：解出来能直接打开并读到数据', async () => {
    const { store } = seedStore(join(root, 'snap', 'data'));
    const tgz = join(root, 'snap.tar.gz');
    await backupToFile(store, tgz);

    const dir = mkdtempSync(join(root, 'x-'));
    execFileSync('tar', ['-xzf', tgz, '-C', dir]);

    const db = new DatabaseSync(join(dir, 'world.db'), { readOnly: true });
    const rows = db.prepare('SELECT id FROM characters').all() as { id: string }[];
    db.close();
    assert.deepEqual(rows.map((r) => r.id), ['c1']);
  });

  it('资产字节在包里是原样的（不是空文件/不是被截断的）', async () => {
    const { store, spriteHash } = seedStore(join(root, 'bytes', 'data'));
    const tgz = join(root, 'bytes.tar.gz');
    await backupToFile(store, tgz);

    const dir = mkdtempSync(join(root, 'y-'));
    execFileSync('tar', ['-xzf', tgz, '-C', dir]);
    const bytes = readFileSync(join(dir, 'assets', spriteHash));
    assert.deepEqual([...bytes], [1, 2, 3, 4, 5]);
  });

  it('内存 store（无 dataDir）不能备份，明确报错而不是产出空包', () => {
    const mem = new WorldStore();
    assert.throws(() => startBackup(mem), /persistent data dir/);
  });
});

describe('全量备份导入', () => {
  let root: string;
  before(() => {
    root = mkdtempSync(join(tmpdir(), 'maliang-rs-'));
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  it('把 A 的包导进 B：B 的旧数据被换成 A 的，且资产跟着过来', async () => {
    // A：有角色 c1 + 一张立绘
    const { store: a, spriteHash } = seedStore(join(root, 'a', 'data'));
    const tgz = join(root, 'a.tar.gz');
    await backupToFile(a, tgz);

    // B：完全不同的数据（角色 other、没有 A 的资产）
    const bDir = join(root, 'b', 'data');
    const b = new WorldStore(bDir);
    b.createWorld('w-other');
    b.addCharacter({ id: 'other', worldId: 'w-other', name: '别的', persona: '', voiceId: 'v' } as never);
    assert.equal(b.getAsset(spriteHash), undefined, '前置：B 本来没有 A 的立绘');

    const res = await restoreBackup(b, tgz);

    // 换成了 A 的世界与角色
    assert.equal(res.manifest.counts.characters, 1);
    assert.ok(b.getWorld('w1'), '导入后应有 A 的世界 w1');
    assert.equal(b.getWorld('w-other'), undefined, 'B 原来的世界应被整个换掉');
    // 资产真的跟过来了（内存态 + 落盘都对）
    const asset = b.getAsset(spriteHash);
    assert.ok(asset, '导入后应能取到 A 的立绘资产');
    assert.deepEqual([...asset.bytes], [1, 2, 3, 4, 5]);
    assert.ok(existsSync(join(bDir, 'assets', spriteHash)), '立绘应落在 B 的 assets/ 下');
    // idle 动画记录也在
    assert.equal(b.getSpriteAnim(spriteHash)?.status, 'ready');
  });

  it('导入前自动把当前数据另存一份，导错了还能拿回来', async () => {
    const { store: a } = seedStore(join(root, 'a2', 'data'));
    const tgz = join(root, 'a2.tar.gz');
    await backupToFile(a, tgz);

    const bDir = join(root, 'b2', 'data');
    const b = new WorldStore(bDir);
    b.createWorld('precious');
    b.addCharacter({ id: 'keepme', worldId: 'precious', name: '别弄丢我', persona: '', voiceId: 'v' } as never);

    const res = await restoreBackup(b, tgz);
    assert.ok(existsSync(res.preRestoreBackup), 'pre-restore 兜底包应真的落盘了');

    // 把兜底包再导回去 —— 覆盖前的数据应当原样回来
    const back = await restoreBackup(b, res.preRestoreBackup);
    assert.equal(back.manifest.counts.characters, 1);
    assert.ok(b.getWorld('precious'), '兜底包应能把覆盖前的世界救回来');
    assert.ok(b.getWorld('w1') === undefined, '救回来之后不该还留着 A 的世界');
  });

  it('坏包（不是 gzip）被拒绝，且现网数据一个字节都不动', async () => {
    const bDir = join(root, 'b3', 'data');
    const b = new WorldStore(bDir);
    b.createWorld('intact');
    const bad = join(root, 'bad.tar.gz');
    writeFileSync(bad, Buffer.from('这不是一个 tar.gz'));

    await assert.rejects(() => restoreBackup(b, bad), /有效的备份包/);
    assert.ok(b.getWorld('intact'), '导入失败后现网数据必须原样还在');
  });

  it('版本不匹配的包被拒绝（宁可失败，不导半套数据）', async () => {
    const { store: a } = seedStore(join(root, 'a4', 'data'));
    const tgz = join(root, 'a4.tar.gz');
    await backupToFile(a, tgz);

    // 篡改包里的 manifest 版本，重新打包
    const dir = mkdtempSync(join(root, 'z-'));
    execFileSync('tar', ['-xzf', tgz, '-C', dir]);
    const m = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8')) as BackupManifest;
    m.version = BACKUP_VERSION + 99;
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify(m));
    const tampered = join(root, 'tampered.tar.gz');
    execFileSync('tar', [
      '-czf', tampered, '-C', dir,
      'manifest.json', 'world.db', 'assets.json', 'sprite_anims.json', 'assets',
    ]);

    const b = new WorldStore(join(root, 'b4', 'data'));
    b.createWorld('intact');
    await assert.rejects(() => restoreBackup(b, tampered), /版本/);
    assert.ok(b.getWorld('intact'), '拒绝导入后现网数据必须原样还在');
  });

  it('包里 world.db 不是马良的库 → 拒绝', async () => {
    const dir = mkdtempSync(join(root, 'fake-'));
    // 一个语法合法、但完全不相干的 SQLite 库
    const db = new DatabaseSync(join(dir, 'world.db'));
    db.exec('CREATE TABLE unrelated (x TEXT)');
    db.close();
    writeFileSync(join(dir, 'manifest.json'), JSON.stringify({
      version: BACKUP_VERSION, createdAt: Date.now(), gitSha: 'x',
      counts: { players: 0, worlds: 0, characters: 0, items: 0, assets: 0, spriteAnims: 0 },
    }));
    writeFileSync(join(dir, 'assets.json'), '{}');
    writeFileSync(join(dir, 'sprite_anims.json'), '{}');
    execFileSync('mkdir', ['-p', join(dir, 'assets')]);
    const fake = join(root, 'fake.tar.gz');
    execFileSync('tar', [
      '-czf', fake, '-C', dir,
      'manifest.json', 'world.db', 'assets.json', 'sprite_anims.json', 'assets',
    ]);

    const b = new WorldStore(join(root, 'b5', 'data'));
    b.createWorld('intact');
    await assert.rejects(() => restoreBackup(b, fake), /不是马良的库/);
    assert.ok(b.getWorld('intact'));
  });
});

describe('备份端点门禁', () => {
  let app: FastifyInstance;
  let dataDir: string;
  before(async () => {
    dataDir = mkdtempSync(join(tmpdir(), 'maliang-ep-'));
    process.env.MALIANG_ADMIN_TOKEN = TOKEN;
    process.env.MALIANG_DATA_DIR = join(dataDir, 'data');
    app = await buildServer();
  });
  after(async () => {
    await app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
    delete process.env.MALIANG_DATA_DIR;
    rmSync(dataDir, { recursive: true, force: true });
  });

  it('无 token → 403', async () => {
    const res = await app.inject({ method: 'GET', url: '/admin/backup' });
    assert.equal(res.statusCode, 403);
  });

  it('带 token → 下发一个能解开的 tar.gz，manifest 在响应头里', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/admin/backup',
      headers: { 'x-admin-token': TOKEN },
    });
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['content-type'], 'application/gzip');
    assert.match(String(res.headers['content-disposition']), /maliang-backup-\d{8}-\d{6}\.tar\.gz/);
    const manifest = JSON.parse(String(res.headers['x-backup-manifest'])) as BackupManifest;
    assert.equal(manifest.version, BACKUP_VERSION);

    // 真正的验收：下发的字节能被 tar 解开
    const tgz = join(dataDir, 'downloaded.tar.gz');
    writeFileSync(tgz, res.rawPayload);
    const listing = execFileSync('tar', ['-tzf', tgz], { encoding: 'utf8' });
    assert.match(listing, /world\.db/);
    assert.match(listing, /manifest\.json/);
  });

  it('导入无 token → 403', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/admin/restore',
      headers: { 'content-type': 'application/gzip' },
      payload: Buffer.from('x'),
    });
    assert.equal(res.statusCode, 403);
  });

  it('导入坏包 → 400，且明确说是包的问题', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/admin/restore',
      headers: { 'x-admin-token': TOKEN, 'content-type': 'application/gzip' },
      payload: Buffer.from('这不是 tar.gz'),
    });
    assert.equal(res.statusCode, 400);
    assert.match(JSON.parse(res.payload).error, /有效的备份包/);
  });

  /**
   * 端到端往返 —— 这条才是老板真正买单的那件事：
   * 世界毁了以后，拿着导出的包，能不能把数据一模一样地拿回来。
   */
  it('往返：导出 → 数据被毁 → 导入 → 数据一模一样回来了', async () => {
    // 通过公开 API 造一个真实世界（不是直接戳 store）
    const created = await app.inject({
      method: 'POST',
      url: '/worlds',
      payload: {},
    });
    const worldId = JSON.parse(created.payload).id as string;

    // 导出
    const dump = await app.inject({
      method: 'GET',
      url: '/admin/backup',
      headers: { 'x-admin-token': TOKEN },
    });
    assert.equal(dump.statusCode, 200);
    const tgz = join(dataDir, 'roundtrip.tar.gz');
    writeFileSync(tgz, dump.rawPayload);
    const before = JSON.parse(
      (await app.inject({ method: 'GET', url: '/debug/api/overview', headers: { 'x-admin-token': TOKEN } })).payload,
    ) as { worlds: number };

    // 毁数据：再造几个世界，让现状明显偏离备份那一刻
    for (let i = 0; i < 3; i++) await app.inject({ method: 'POST', url: '/worlds', payload: {} });
    const damaged = JSON.parse(
      (await app.inject({ method: 'GET', url: '/debug/api/overview', headers: { 'x-admin-token': TOKEN } })).payload,
    ) as { worlds: number };
    assert.equal(damaged.worlds, before.worlds + 3, '前置：数据确实被改乱了');

    // 导入备份
    const restored = await app.inject({
      method: 'POST',
      url: '/admin/restore',
      headers: { 'x-admin-token': TOKEN, 'content-type': 'application/gzip' },
      payload: readFileSync(tgz),
    });
    assert.equal(restored.statusCode, 200, restored.payload);
    const body = JSON.parse(restored.payload) as { ok: boolean; preRestoreBackup: string };
    assert.equal(body.ok, true);
    assert.ok(existsSync(body.preRestoreBackup), '覆盖前的兜底包应真的落盘');

    // 数据回到了备份那一刻：世界数一致，且备份里那个世界还在（服务端立刻可用，无需重启）
    const after = JSON.parse(
      (await app.inject({ method: 'GET', url: '/debug/api/overview', headers: { 'x-admin-token': TOKEN } })).payload,
    ) as { worlds: number };
    assert.equal(after.worlds, before.worlds, '导入后世界数应回到备份那一刻');
    const w = await app.inject({ method: 'GET', url: `/debug/api/worlds/${worldId}`, headers: { 'x-admin-token': TOKEN } });
    assert.equal(w.statusCode, 200, '备份里的世界导入后应当还在，且服务端不用重启就能读到');
  });
});
