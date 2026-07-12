#!/usr/bin/env python3
"""程序化平色图案地形贴图（themed-terrain P3）。

CC0 光扫纹理拿不到干净图案的 tile（斑马线/地毯/拼图垫/棋盘格/医用地胶/发光格/警戒条纹）
用本工具生成——纯几何图案 + 轻纸纹 + 柔边，契合游戏「①卡通光滑白卡纸」画风，
比 AIGC 材质照片更过审（memory 贴图资产审美底线）。全部 1024²、无缝可平铺
（图案周期整除 1024）、输出 RGB，tint 已含在图案色里 → 层 tint/mean 传 _WHITE。

用法：gen_pattern_tex.py <kind> <out.png> [--size 1024] [其它 kind 专属参数]
  kind ∈ crosswalk / carpet / puzzle / checker / vinyl / glow / hazard
"""
import sys, argparse
import numpy as np
from PIL import Image


def paper_grain(rng, size, amt=0.03):
    g = rng.normal(0, 1, (size, size))
    g = (g - g.mean()) / (g.std() + 1e-8)
    return g[..., None] * amt


def soften(a, k=1.5):
    """轻微环绕高斯柔化边（保无缝）。"""
    if k <= 0:
        return a
    h, w = a.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    g = np.exp(-2.0 * (np.pi ** 2) * (k ** 2) * (fy ** 2 + fx ** 2))
    out = np.empty_like(a)
    for c in range(a.shape[2]):
        out[:, :, c] = np.real(np.fft.ifft2(np.fft.fft2(a[:, :, c]) * g))
    return out


def hx(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32) / 255.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("kind")
    ap.add_argument("out")
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--base", type=str, default="", help="底色 #RRGGBB")
    ap.add_argument("--fg", type=str, default="", help="前景/条纹色 #RRGGBB")
    ap.add_argument("--period", type=int, default=8, help="图案周期数（整除 size 保无缝）")
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    n = a.size
    rng = np.random.default_rng(a.seed)
    yy, xx = np.mgrid[0:n, 0:n]
    out = np.zeros((n, n, 3), np.float32)

    if a.kind == "crosswalk":
        base = hx(a.base or "3a3d40"); fg = hx(a.fg or "d8d8d0")
        out[:] = base
        bar = ((yy // (n // a.period)) % 2 == 0)  # 横向白条交替
        out[bar] = fg
        out += paper_grain(rng, n, 0.025)
        out = soften(out, 1.2)

    elif a.kind == "carpet":
        base = hx(a.base or "b23a3a")
        out[:] = base
        # 绒毛：细高频噪声 + 低频斑
        fib = rng.normal(0, 1, (n, n))[..., None] * 0.05
        blot = soften(rng.normal(0, 1, (n, n, 1)).repeat(3, 2), 4.0) * 0.04
        out = out * (1 + fib) + blot
        out += paper_grain(rng, n, 0.015)

    elif a.kind == "puzzle":
        # 互扣泡沫垫：period×period 方块，柔和四色循环 + 块间浅缝
        cols = [hx("c94f4f"), hx("4f6fc9"), hx("d1a53a"), hx("4faf6f")]
        cell = n // a.period
        idx = ((xx // cell) + (yy // cell)) % 4
        for k in range(4):
            out[idx == k] = cols[k]
        # 块间浅缝（暗线）
        seam = ((xx % cell < 3) | (yy % cell < 3))
        out[seam] *= 0.82
        out += paper_grain(rng, n, 0.02)
        out = soften(out, 1.0)

    elif a.kind == "checker":
        base = hx(a.base or "e8e4da"); fg = hx(a.fg or "3b3b40")
        cell = n // a.period
        chk = ((xx // cell) + (yy // cell)) % 2 == 0
        out[:] = base; out[chk] = fg
        out += paper_grain(rng, n, 0.02)
        out = soften(out, 1.2)

    elif a.kind == "vinyl":
        base = hx(a.base or "cfe7d8")  # 极浅纯色医用地胶
        out[:] = base
        out += paper_grain(rng, n, 0.012)
        # 极淡低频斑（PVC 观感）
        out += soften(rng.normal(0, 1, (n, n, 1)).repeat(3, 2), 6.0) * 0.02

    elif a.kind == "glow":
        base = hx(a.base or "10202a"); fg = hx(a.fg or "3fd8e6")  # 深底 + 青蓝发光格线
        out[:] = base
        cell = n // a.period
        line = ((xx % cell < 6) | (yy % cell < 6))
        out[line] = fg
        # 发光晕：格线附近提亮
        glow = soften((line[..., None].astype(np.float32)).repeat(3, 2), 3.0)
        out = np.clip(out + glow * fg[None, None, :] * 0.5, 0, 1)
        out += paper_grain(rng, n, 0.01)

    elif a.kind == "hazard":
        base = hx(a.base or "e6c02a"); fg = hx(a.fg or "26241f")  # 黄底 + 黑斜条
        out[:] = base
        stripe = (((xx + yy) // (n // a.period)) % 2 == 0)  # 45° 斜条
        out[stripe] = fg
        out += paper_grain(rng, n, 0.02)
        out = soften(out, 1.3)

    else:
        sys.exit(f"unknown kind '{a.kind}'")

    out = np.clip(out, 0, 1)
    Image.fromarray((out * 255).astype(np.uint8)).save(a.out)
    print(f"wrote {a.out} ({a.kind})")


if __name__ == "__main__":
    main()
