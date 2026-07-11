/**
 * 库体检与清理。
 *
 * 死引用 = 库里记着某张立绘、资产库里却没有那个文件。真实成因见 2026-07-09：
 * 切 ghcr 部署时 assets/ 里 7/9 之前的文件没搬过去，world.db 搬过去了——
 * 库记得那张图，盘上没有，客户端只能一直拿 404。
 *
 * 清理端点默认 dry-run：误调一次不会毁数据。
 */
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WorldStore } from '../src/persistence.ts';
import { buildServer } from '../src/server.ts';
import type { FastifyInstance } from 'fastify';

const TOKEN = 'test-admin-token';

/**
 * 造一个"库里记着、盘上没有"的死引用——精确复刻线上那次事故：
 * 先正常生成资产并被引用，再把资产文件从盘上拿走（模拟迁移没搬过去），然后重启 store。
 */
function seedDeadRef(dir: string): { store: WorldStore; deadHash: string; goodHash: string } {
  const s1 = new WorldStore(dir);
  const deadHash = s1.putAsset({ bytes: new Uint8Array([1, 2, 3]), mime: 'image/png' });
  const goodHash = s1.putAsset({ bytes: new Uint8Array([4, 5, 6]), mime: 'image/png' });
  s1.upsertPlayer({
    id: 'p-dead', name: '小乐高', nickname: '小乐高', gender: 'boy', color: '红',
    spriteAsset: deadHash, createdAt: '2026-07-08T13:15:00Z',
  });
  s1.upsertPlayer({
    id: 'p-good', name: '小乐高', nickname: '小乐高', gender: 'boy', color: '蓝',
    spriteAsset: goodHash, createdAt: '2026-07-10T13:09:00Z',
  });
  s1.createWorld('w1');
  s1.addCharacter({
    id: 'c-dead', worldId: 'w1', name: '瞌睡喵', persona: '', voiceId: 'v',
    appearance: { spriteAsset: deadHash },
  } as never);

  // 迁移没搬过去：文件从盘上消失，但库里的引用还在
  unlinkSync(join(dir, 'assets', deadHash));
  return { store: new WorldStore(dir), deadHash, goodHash };
}

describe('库体检：死资产引用', () => {
  let root: string;
  before(() => {
    root = mkdtempSync(join(tmpdir(), 'maliang-int-'));
  });
  after(() => rmSync(root, { recursive: true, force: true }));

  it('找得出死引用，且不误伤好的引用', () => {
    const { store, deadHash, goodHash } = seedDeadRef(join(root, 'scan'));
    const dead = store.listDeadSpriteRefs();

    assert.equal(dead.length, 2, '一个玩家 + 一个角色引用了那张没了的图');
    assert.ok(dead.every((d) => d.hash === deadHash), '报出来的都该是那张死图');
    assert.ok(dead.some((d) => d.kind === 'player' && d.id === 'p-dead'));
    assert.ok(dead.some((d) => d.kind === 'character' && d.id === 'c-dead'));
    assert.ok(!dead.some((d) => d.hash === goodHash), '好的引用绝不能被当成死引用');
  });

  it('hasAsset 只查清单不读盘（盘上文件没了就是 false）', () => {
    const { store, deadHash, goodHash } = seedDeadRef(join(root, 'has'));
    assert.equal(store.hasAsset(deadHash), false);
    assert.equal(store.hasAsset(goodHash), true);
  });

  it('清理只置空死引用，好的形象一根汗毛都不动', () => {
    const dir = join(root, 'fix');
    const { store, goodHash } = seedDeadRef(dir);

    const n = store.clearDeadSpriteRefs();
    assert.equal(n, 2);

    assert.equal(store.getPlayer('p-dead')?.spriteAsset, '', '死引用置空');
    assert.equal(store.getPlayer('p-good')?.spriteAsset, goodHash, '好玩家的形象必须原样保留');
    const c = store.getWorld('w1')?.characters.get('c-dead');
    assert.equal(c?.appearance?.spriteAsset, '', '角色的死引用也置空');

    assert.equal(store.listDeadSpriteRefs().length, 0, '清完就不该再有死引用');
    // 清理是幂等的：再跑一次没得清
    assert.equal(store.clearDeadSpriteRefs(), 0);
  });

  it('benchmark 样本：能列出来，也能按 GPU+设备精确删掉', () => {
    const store = new WorldStore();
    store.putDeviceSample({ gpu: 'Mali-G57', benchVersion: 1, deviceId: 'real-tablet', levels: { fog: 1 }, p95Ms: 30, hit: true } as never);
    store.putDeviceSample({ gpu: 'TestGPU 999', benchVersion: 1, deviceId: 'curl-probe', levels: { fog: 0 }, p95Ms: 40, hit: true } as never);

    assert.equal(store.listDeviceSamples().length, 2);
    assert.equal(store.deleteDeviceSample('TestGPU 999', 'curl-probe'), 1, '删掉测试探针那条');

    const left = store.listDeviceSamples();
    assert.equal(left.length, 1);
    assert.equal(left[0]!.deviceId, 'real-tablet', '真机那条必须留着');
  });
});

describe('体检/清理端点', () => {
  let app: FastifyInstance;
  let dir: string;
  let store: WorldStore;

  before(async () => {
    dir = mkdtempSync(join(tmpdir(), 'maliang-intep-'));
    process.env.MALIANG_ADMIN_TOKEN = TOKEN;
    ({ store } = seedDeadRef(join(dir, 'data')));
    store.putDeviceSample({ gpu: 'TestGPU 999', benchVersion: 1, deviceId: 'curl-probe', levels: { fog: 0 }, p95Ms: 40, hit: true } as never);
    app = await buildServer({ store });
  });
  after(async () => {
    await app.close();
    delete process.env.MALIANG_ADMIN_TOKEN;
    rmSync(dir, { recursive: true, force: true });
  });

  it('无 token → 403（体检和清理都得挡住）', async () => {
    assert.equal((await app.inject({ method: 'GET', url: '/admin/integrity' })).statusCode, 403);
    assert.equal((await app.inject({ method: 'POST', url: '/admin/integrity/fix?apply=true' })).statusCode, 403);
  });

  it('体检是只读的：报出死引用，但不改任何东西', async () => {
    const res = await app.inject({ method: 'GET', url: '/admin/integrity', headers: { 'x-admin-token': TOKEN } });
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.payload) as { deadSpriteRefs: unknown[]; deviceSamples: unknown[] };
    assert.equal(body.deadSpriteRefs.length, 2);
    assert.equal(body.deviceSamples.length, 1);
    // 只读：体检完死引用还在
    assert.equal(store.listDeadSpriteRefs().length, 2, '体检不该改数据');
  });

  /** 这条是安全网：万一有人误调 /admin/integrity/fix，不该毁掉任何数据。 */
  it('不带 apply → dry-run：只报告，一个字节都不动', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/admin/integrity/fix',
      headers: { 'x-admin-token': TOKEN },
      payload: { deviceSamples: [{ gpu: 'TestGPU 999', deviceId: 'curl-probe' }] },
    });
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.payload) as { dryRun: boolean; wouldClearSpriteRefs: unknown[] };
    assert.equal(body.dryRun, true);
    assert.equal(body.wouldClearSpriteRefs.length, 2);

    assert.equal(store.listDeadSpriteRefs().length, 2, 'dry-run 之后死引用必须还在');
    assert.equal(store.listDeviceSamples().length, 1, 'dry-run 之后样本必须还在');
  });

  it('带 apply=true → 真清：死引用置空 + 点名的测试样本删掉', async () => {
    const res = await app.inject({
      method: 'POST',
      url: '/admin/integrity/fix?apply=true',
      headers: { 'x-admin-token': TOKEN },
      payload: { deviceSamples: [{ gpu: 'TestGPU 999', deviceId: 'curl-probe' }] },
    });
    assert.equal(res.statusCode, 200);
    const body = JSON.parse(res.payload) as { clearedSpriteRefs: number; deletedDeviceSamples: number };
    assert.equal(body.clearedSpriteRefs, 2);
    assert.equal(body.deletedDeviceSamples, 1);

    assert.equal(store.listDeadSpriteRefs().length, 0);
    assert.equal(store.listDeviceSamples().length, 0);
    assert.equal(store.getPlayer('p-good')?.spriteAsset !== '', true, '好玩家的形象不受影响');
  });
});
