/**
 * 生成一个服务端编码的 v3 地形 blob，写到 test/fixtures/v3_crosscheck.mltr，
 * 供客户端 test_terrain_v3_crosscheck.gd 加载断言——这是「两端 u16 字节对齐」的
 * 唯一真跨实现校验（服务端 DataView LE 编 ↔ 客户端 decode_u16 LE 解）。
 *
 * 契约值（生成器与客户端测试必须一致，改一处两处都要改）：
 *   palette = it0..it255（256 项，触发 v3）
 *   tile (20,20)：itemRef=256（→ palette[255]=it255）、itemArg=64（90°）
 *   tile (20,20) 边缘 W(side=3)：ref=200（→ palette[199]=it199）
 *   其余全空。
 *
 * 运行：node server/test/gen_v3_fixture.ts（从 server 目录：node test/gen_v3_fixture.ts）
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { emptyTerrain, encodeTerrain, REQUIRED_GRID, EDGE_W } from '../src/terrain.ts';

const t = emptyTerrain();
t.palette = Array.from({ length: 256 }, (_, i) => `it${i}`);
const idx = 20 * REQUIRED_GRID + 20;
t.itemRef[idx] = 256;   // 高于 u8 上限的 palette 索引 → it255
t.itemArg[idx] = 64;    // 90°
t.edges[EDGE_W][idx] = 200;  // 边缘也走高索引 → it199

const buf = encodeTerrain(t);
if (buf[4] !== 3) throw new Error(`期望 v3(版本位 3)，实得 ${buf[4]}`);

// 输出到客户端 test/fixtures（worktree 根的相对路径）
const out = resolve(import.meta.dirname, '../../test/fixtures/v3_crosscheck.mltr');
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, buf);
console.log(`wrote ${buf.length} B v3 fixture → ${out}`);
