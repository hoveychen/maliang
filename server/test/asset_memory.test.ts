/**
 * 资产不再全量常驻内存：启动只加载清单（hash→mime），字节按需读盘 + LRU 缓存。
 *
 * 旧实现在构造时把 assets/ 下每个文件都 readFileSync 进一个内存 Map，
 * 常驻内存随角色数线性增长（生产 122 个资产 = 70MB 白占）。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, unlinkSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore } from '../src/persistence.ts';

/** 造一张指定大小的假资产（内容按 seed 变化，保证 hash 不同）。 */
function blob(seed: number, size: number) {
  const bytes = new Uint8Array(size);
  bytes.fill(seed % 256);
  bytes[0] = seed & 0xff;
  bytes[1] = (seed >> 8) & 0xff;
  return { bytes, mime: 'image/png' };
}

describe('资产按需读盘（不再全量常驻内存）', () => {
  let root: string;
  before(() => {
    root = mkdtempSync(join(tmpdir(), 'maliang-lru-'));
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  /**
   * 这条是新旧实现的分水岭：
   * 旧实现启动时已把字节吸进内存，磁盘文件删掉照样能从 Map 里拿到 → 会返回数据。
   * 新实现启动只读清单，字节要用时才回源读盘 → 文件没了就该拿不到。
   */
  it('启动不吸字节进内存：新 store 起来后删掉磁盘文件，就真的读不到了', () => {
    const dir = join(root, 'ondemand');
    const s1 = new WorldStore(dir);
    const hash = s1.putAsset(blob(1, 1024));

    // 重开一个 store（模拟进程重启）：此时它应当只加载了清单，没读字节
    const s2 = new WorldStore(dir);
    const file = join(dir, 'assets', hash);
    assert.ok(existsSync(file), '前置：资产文件在盘上');
    unlinkSync(file); // 把字节从盘上拿走

    assert.equal(
      s2.getAsset(hash),
      undefined,
      '字节应当是按需从盘上读的——文件没了就该读不到，而不是从启动时吸进内存的副本里返回',
    );
  });

  it('按需读盘读到的字节是对的（跨重启一致）', () => {
    const dir = join(root, 'roundtrip');
    const s1 = new WorldStore(dir);
    const hash = s1.putAsset({ bytes: new Uint8Array([7, 7, 7, 42]), mime: 'image/webp' });

    const s2 = new WorldStore(dir);
    const got = s2.getAsset(hash);
    assert.ok(got, '重启后应当仍能取到资产');
    assert.deepEqual([...got.bytes], [7, 7, 7, 42]);
    assert.equal(got.mime, 'image/webp', 'mime 从清单里恢复');
  });

  it('LRU 驱逐不丢数据：超出缓存预算后，被驱逐的资产仍能从盘上读回来', () => {
    const dir = join(root, 'evict');
    // 缓存预算 10KB，每张 4KB → 塞 5 张必然驱逐
    const s = new WorldStore(dir, { assetCacheBytes: 10 * 1024 });
    const hashes: string[] = [];
    for (let i = 0; i < 5; i++) hashes.push(s.putAsset(blob(i, 4 * 1024)));

    // 全都还能读到（缓存里的 + 被驱逐后回源读盘的），且字节正确
    for (let i = 0; i < 5; i++) {
      const got = s.getAsset(hashes[i]!);
      assert.ok(got, `第 ${i} 张应当仍能取到（被驱逐就回源读盘）`);
      assert.equal(got.bytes.length, 4 * 1024);
      assert.equal(got.bytes[1], (i >> 8) & 0xff, `第 ${i} 张的字节应当是它自己的，不能串味`);
      assert.equal(got.bytes[0], i & 0xff);
    }
  });

  it('内存 store（无 dataDir）永不驱逐——缓存就是唯一落点，驱逐等于丢数据', () => {
    const s = new WorldStore(undefined, { assetCacheBytes: 1024 }); // 预算故意设得极小
    const hashes: string[] = [];
    for (let i = 0; i < 20; i++) hashes.push(s.putAsset(blob(i, 4 * 1024))); // 远超预算

    for (let i = 0; i < 20; i++) {
      const got = s.getAsset(hashes[i]!);
      assert.ok(got, `内存 store 里第 ${i} 张不该被驱逐（没有磁盘可回源）`);
      assert.equal(got.bytes[0], i & 0xff);
    }
  });

  it('清单跨重启保留（备份导出的 assets.json 靠它）', () => {
    const dir = join(root, 'manifest');
    const s1 = new WorldStore(dir);
    const h1 = s1.putAsset({ bytes: new Uint8Array([1]), mime: 'image/png' });
    const h2 = s1.putAsset({ bytes: new Uint8Array([2]), mime: 'audio/wav' });

    const idx = JSON.parse(readFileSync(join(dir, 'assets.json'), 'utf8')) as Record<string, string>;
    assert.equal(idx[h1], 'image/png');
    assert.equal(idx[h2], 'audio/wav');

    // 重启后备份快照里的 mime 仍然对得上
    const s2 = new WorldStore(dir);
    const staging = join(root, 'staging');
    const m = s2.exportSnapshot(staging);
    assert.equal(m.counts.assets, 2, '快照的资产计数应当来自清单，而不是内存里缓存了几张');
    const snapIdx = JSON.parse(readFileSync(join(staging, 'assets.json'), 'utf8')) as Record<string, string>;
    assert.equal(snapIdx[h2], 'audio/wav');
  });

  it('清单里有、盘上没有的孤儿条目 → getAsset 返回 undefined，不炸', () => {
    const dir = join(root, 'orphan');
    const s1 = new WorldStore(dir);
    s1.putAsset({ bytes: new Uint8Array([9]), mime: 'image/png' });
    // 手工往清单里塞一个盘上不存在的 hash（模拟盘被动过 / 半截恢复）
    const mf = join(dir, 'assets.json');
    const idx = JSON.parse(readFileSync(mf, 'utf8')) as Record<string, string>;
    idx['deadbeefdeadbeef'] = 'image/png';
    writeFileSync(mf, JSON.stringify(idx));

    const s2 = new WorldStore(dir);
    assert.equal(s2.getAsset('deadbeefdeadbeef'), undefined, '孤儿条目应当安静地返回 undefined');
  });
});
