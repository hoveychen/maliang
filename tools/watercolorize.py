#!/usr/bin/env python3
"""CC0 光扫纹理 -> 水彩/白卡纸风格化。

目标画风参考 assets/textures/watercolor/{grass,dirt,stone}.png：
  极柔和低频色值变化 + 去饱和 + 色调分离(posterize) + 纸纹 granulation + 去高频。
所有操作走环绕(wrap)以保持无缝可平铺。
"""
import sys, argparse, json, os
import numpy as np
from PIL import Image


def load_rgb(path, size):
    im = Image.open(path).convert("RGB")
    if im.size != (size, size):
        im = im.resize((size, size), Image.LANCZOS)
    return np.asarray(im, dtype=np.float32) / 255.0


def seamless_gaussian(a, sigma):
    """FFT gaussian blur with periodic (wrap) boundary -> stays tileable."""
    if sigma <= 0:
        return a
    h, w = a.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.fftfreq(w)[None, :]
    # gaussian in freq domain: exp(-2 pi^2 sigma^2 f^2)
    g = np.exp(-2.0 * (np.pi ** 2) * (sigma ** 2) * (fy ** 2 + fx ** 2))
    out = np.empty_like(a)
    chans = 1 if a.ndim == 2 else a.shape[2]
    for c in range(chans):
        ch = a if a.ndim == 2 else a[:, :, c]
        F = np.fft.fft2(ch)
        blurred = np.real(np.fft.ifft2(F * g))
        if a.ndim == 2:
            out = blurred
        else:
            out[:, :, c] = blurred
    return out


def rgb_to_hsv(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mx = np.max(a, axis=-1)
    mn = np.min(a, axis=-1)
    df = mx - mn + 1e-8
    h = np.zeros_like(mx)
    mask = mx == r
    h[mask] = ((g[mask] - b[mask]) / df[mask]) % 6
    mask = mx == g
    h[mask] = ((b[mask] - r[mask]) / df[mask]) + 2
    mask = mx == b
    h[mask] = ((r[mask] - g[mask]) / df[mask]) + 4
    h = h / 6.0
    s = df / (mx + 1e-8)
    v = mx
    return np.stack([h, s, v], axis=-1)


def hsv_to_rgb(a):
    h, s, v = a[..., 0] * 6.0, a[..., 1], a[..., 2]
    i = np.floor(h).astype(int)
    f = h - i
    p = v * (1 - s)
    q = v * (1 - s * f)
    t = v * (1 - s * (1 - f))
    i = i % 6
    r = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [v, q, p, p, t, v])
    g = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [t, v, v, q, p, p])
    b = np.select([i == 0, i == 1, i == 2, i == 3, i == 4, i == 5], [p, p, t, v, v, q])
    return np.clip(np.stack([r, g, b], axis=-1), 0, 1)


def posterize_luma(v, levels):
    """Soft posterize of a value channel into `levels` bands (tonal separation)."""
    q = np.round(v * (levels - 1)) / (levels - 1)
    return q


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--size", type=int, default=1024)
    ap.add_argument("--struct-sigma", type=float, default=6.0,
                    help="blur to extract large-scale wash structure")
    ap.add_argument("--detail-keep", type=float, default=0.18,
                    help="fraction of mid-freq detail retained")
    ap.add_argument("--sat", type=float, default=0.55, help="saturation multiplier")
    ap.add_argument("--contrast", type=float, default=0.7, help="value contrast (1=full)")
    ap.add_argument("--levels", type=int, default=6, help="posterize bands")
    ap.add_argument("--poster-mix", type=float, default=0.55,
                    help="blend toward posterized value")
    ap.add_argument("--lift", type=float, default=0.06, help="shadow lift")
    ap.add_argument("--paper", type=float, default=0.10, help="paper grain opacity")
    ap.add_argument("--granule", type=float, default=0.06, help="pigment granulation opacity")
    ap.add_argument("--edge-pool", type=float, default=0.12, help="edge pigment pooling")
    ap.add_argument("--tint", type=str, default="", help="target grade color 'R,G,B' 0-255")
    ap.add_argument("--tint-amt", type=float, default=0.0, help="grade strength 0-1")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--preset-file", type=str, default="",
                    help="JSON of {key: {param: val}}; params fill in as defaults")
    ap.add_argument("--preset", type=str, default="",
                    help="key into --preset-file to apply (explicit CLI flags still win)")
    args = ap.parse_args()

    # apply preset as defaults for any flag the caller did NOT pass explicitly
    if args.preset:
        if not args.preset_file:
            sys.exit("--preset requires --preset-file")
        with open(args.preset_file) as f:
            presets = json.load(f)
        if args.preset not in presets:
            sys.exit(f"preset '{args.preset}' not in {args.preset_file}; "
                     f"have {list(presets)}")
        passed = {a.lstrip("-").replace("-", "_") for a in sys.argv[1:] if a.startswith("--")}
        for k, v in presets[args.preset].items():
            attr = k.replace("-", "_")
            if attr in passed:
                continue  # explicit CLI flag overrides preset
            if hasattr(args, attr):
                setattr(args, attr, v)

    rng = np.random.default_rng(args.seed)
    img = load_rgb(args.src, args.size)

    # 1. split into large-scale wash + attenuated detail (kills high freq)
    wash = seamless_gaussian(img, args.struct_sigma)
    detail = img - wash
    img2 = wash + detail * args.detail_keep

    # 2. to HSV; desaturate + compress value contrast toward a soft midtone
    hsv = rgb_to_hsv(np.clip(img2, 0, 1))
    hsv[..., 1] *= args.sat
    v = hsv[..., 2]
    vmid = v.mean()
    v = (v - vmid) * args.contrast + vmid
    v = v * (1 - args.lift) + args.lift  # lift shadows toward paper white

    # 3. tonal separation: blend toward posterized value (watercolor flat bands)
    vp = posterize_luma(np.clip(v, 0, 1), args.levels)
    vp = seamless_gaussian(vp, 1.2)  # soften band edges
    v = v * (1 - args.poster_mix) + vp * args.poster_mix
    hsv[..., 2] = np.clip(v, 0, 1)
    out = hsv_to_rgb(hsv)

    # 3b. optional color grade toward a target tint (preserves local value)
    if args.tint and args.tint_amt > 0:
        tgt = np.array([float(x) for x in args.tint.split(",")], dtype=np.float32) / 255.0
        lum = out.mean(axis=-1, keepdims=True)
        # target ramp: dark->0, mid->tgt, keeps luminance structure
        graded = tgt[None, None, :] * (lum / (lum.mean() + 1e-8)) * 0.85 + tgt[None, None, :] * 0.15
        out = out * (1 - args.tint_amt) + np.clip(graded, 0, 1) * args.tint_amt

    # 4. edge pigment pooling: darken where the wash has gradient (region borders)
    if args.edge_pool > 0:
        lum = out.mean(axis=-1)
        gx = lum - np.roll(lum, 1, axis=1)
        gy = lum - np.roll(lum, 1, axis=0)
        grad = np.sqrt(gx ** 2 + gy ** 2)
        grad = seamless_gaussian(grad, 1.5)
        grad = grad / (grad.max() + 1e-8)
        pool = 1.0 - grad[..., None] * args.edge_pool
        out = out * pool

    # 5. paper grain (fine, seamless) + pigment granulation (low-freq blotch)
    if args.paper > 0:
        grain = rng.normal(0, 1, (args.size, args.size))
        grain = grain - grain.mean()
        grain = grain / (grain.std() + 1e-8)
        out = out * (1 + grain[..., None] * args.paper * 0.12)
    if args.granule > 0:
        blotch = rng.normal(0, 1, (args.size, args.size))
        blotch = seamless_gaussian(blotch, 3.0)
        blotch = blotch / (np.abs(blotch).max() + 1e-8)
        out = out * (1 + blotch[..., None] * args.granule)

    out = np.clip(out, 0, 1)
    Image.fromarray((out * 255).astype(np.uint8)).save(args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
