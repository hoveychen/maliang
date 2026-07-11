/**
 * /assets/:hash 的缓存头。
 *
 * 资产是内容寻址的（hash = 内容的 SHA-256 摘要），同一 URL 的字节永不变化，
 * 所以它本该是最好缓存的一类响应——之前却一个缓存头都没有，每次都白传一遍字节。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { WorldStore } from '../src/persistence.ts';
import { buildServer } from '../src/server.ts';
import type { FastifyInstance } from 'fastify';

describe('资产缓存头', () => {
  let app: FastifyInstance;
  let hash: string;

  before(async () => {
    const store = new WorldStore(); // 内存 store，够测缓存头
    hash = store.putAsset({ bytes: new Uint8Array([9, 8, 7]), mime: 'image/png' });
    app = await buildServer({ store });
  });
  after(async () => {
    await app.close();
  });

  it('资产响应带 immutable 长缓存 + ETag', async () => {
    const res = await app.inject({ method: 'GET', url: `/assets/${hash}` });
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers['cache-control'], 'public, max-age=31536000, immutable');
    assert.equal(res.headers.etag, `"${hash}"`);
    assert.deepEqual([...res.rawPayload], [9, 8, 7]);
  });

  it('ETag 命中 → 304，且不再传字节', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/assets/${hash}`,
      headers: { 'if-none-match': `"${hash}"` },
    });
    assert.equal(res.statusCode, 304);
    assert.equal(res.rawPayload.length, 0, '304 不该带 body');
    assert.equal(res.headers['cache-control'], 'public, max-age=31536000, immutable');
  });

  it('浏览器发的弱校验 W/"..." 也算命中', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/assets/${hash}`,
      headers: { 'if-none-match': `W/"${hash}"` },
    });
    assert.equal(res.statusCode, 304);
  });

  it('ETag 不匹配 → 正常回 200 + 完整字节', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/assets/${hash}`,
      headers: { 'if-none-match': '"某个别的hash"' },
    });
    assert.equal(res.statusCode, 200);
    assert.deepEqual([...res.rawPayload], [9, 8, 7]);
  });

  it('资产不存在仍是 404（缓存头不能把 404 也缓存成永久）', async () => {
    const res = await app.inject({ method: 'GET', url: '/assets/deadbeefdeadbeef' });
    assert.equal(res.statusCode, 404);
    assert.equal(res.headers['cache-control'], undefined);
  });
});
