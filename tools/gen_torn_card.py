#!/usr/bin/env python3
"""menu 撕纸纸艺卡资产（menu-dynamic P2）。

程序化生成竖版白卡纸 + 右侧撕纸毛边 + 烘焙软投影（RGBA PNG），menu 左侧菜单卡用。
光滑白卡纸质感（贴图审美底线：不要 AIGC 材质照片、不要牛皮纸颗粒）；撕边是低频
随机游走 + 高频细齿两层叠加，边内侧一圈提亮当纤维唇口。上/下/左三边直裁（卡出血
到屏幕外），只有右边撕。

用法：uv run --with pillow --with numpy python3 tools/gen_torn_card.py assets/ui/menu_card.png
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

W, H = 1280, 1720
EDGE_X = 1064          # 撕边基准线
EDGE_AMP = 40          # 低频摆幅
FINE_AMP = 7           # 高频细齿
SHADOW_DX = 16         # 投影右偏
SHADOW_BLUR = 22
SHADOW_A = 0.30


def smooth_noise(n, rng, passes=48):
    v = rng.normal(0, 1, n).cumsum()
    k = np.ones(passes) / passes
    for _ in range(3):
        v = np.convolve(v, k, mode="same")
    v -= v.mean()
    v /= (np.abs(v).max() + 1e-8)
    return v


def main(out_path):
    rng = np.random.default_rng(20260715)
    ys = np.arange(H)
    edge = EDGE_X + smooth_noise(H, rng) * EDGE_AMP + rng.normal(0, 1, H) * FINE_AMP
    xs = np.arange(W)[None, :]
    edge_col = edge[:, None]
    inside = xs < edge_col                       # 卡纸本体
    dist_in = np.clip(edge_col - xs, 0, None)    # 距撕边像素数（卡内）

    # 本体：暖白 + 极轻对角渐变 + 微纸纹（光滑卡纸，噪声压到几乎不可见）
    base = np.array([251, 248, 241], dtype=np.float64)
    grad = ((xs / W) * 0.5 + (ys[:, None] / H) * 0.5 - 0.5) * -6.0  # 左上略亮右下略沉
    grain = rng.normal(0, 1, (H, W)) * 1.2
    rgb = base[None, None, :] + grad[:, :, None] + grain[:, :, None]

    # 撕边纤维唇口：边内 0..12px 提亮到纯白，12..26px 轻压暗一线造层次
    lip = np.clip(1.0 - dist_in / 12.0, 0, 1) ** 1.5 * 14.0
    crease = np.exp(-((dist_in - 19.0) ** 2) / (2 * 5.0 ** 2)) * -7.0
    rgb += (lip + crease)[:, :, None]
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)

    alpha = (inside * 255).astype(np.uint8)
    card = Image.fromarray(np.dstack([rgb, alpha]))

    # 烘焙投影：本体 alpha 右移+模糊，铺在卡纸下层
    sh_a = Image.fromarray(alpha).filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    sh_a = np.array(sh_a, dtype=np.float64) * SHADOW_A
    sh_a = np.roll(sh_a, SHADOW_DX, axis=1)
    sh_a[:, :SHADOW_DX] = sh_a[:, SHADOW_DX:SHADOW_DX + 1]  # roll 卷回来的左缘补齐
    shadow = np.zeros((H, W, 4), dtype=np.uint8)
    shadow[:, :, 3] = np.clip(sh_a, 0, 255).astype(np.uint8)
    shadow[:, :, :3] = (40, 32, 24)

    out = Image.alpha_composite(Image.fromarray(shadow), card)
    out.save(out_path)
    print(f"saved {out_path} {W}x{H}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/ui/menu_card.png")
