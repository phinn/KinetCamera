#!/usr/bin/env python3
"""美颜 A/B 皮肤纹理保留度量化。
输入:原图 + 磨皮后图(同尺寸同场景)。
方法:人脸/皮肤候选区取高亮暖色主导块(自动,无需标注),
  逐块算:①高频能量比(拉普拉斯|Δ|,纹理保留度) ②结构相似性(SSIM 近似,涂抹度)
  ③亮度/色度变化(美白效果) ④非肤色区漂移(误伤检查)
输出:数值报告 + /tmp/beauty_ab_v2.png 对比拼图。
用法: beauty_ab.py <before.png> <after.png> [--out /tmp/beauty_ab_v2.png]
"""
import sys, json
import numpy as np
from PIL import Image, ImageDraw


def skin_patch(a: np.ndarray, patch: int = 96, stride: int = 48) -> np.ndarray:
    """找皮肤主导块:RGB 肤色规则(R>G>B 且差值适中)+亮度中高,取最大连通倾向块。
    同时返回该块坐标(对照图必须取同一坐标——美颜走小域缩放,Lanczos 重采样本身有伪差,
    不锁同一块位置的对照就是假对照)。"""
    h, w, _ = a.shape
    best, best_score, best_xy = None, -1.0, (h//2, w//2)
    for y in range(0, max(h - patch, 1), stride):
        for x in range(0, max(w - patch, 1), stride):
            p = a[y:y+patch, x:x+patch].astype(np.float32)
            r, g, b = p[..., 0], p[..., 1], p[..., 2]
            skin = (r > g) & (g > b) & (r - b > 12) & (r - b < 120) & (r > 60) & (r < 250)
            score = skin.mean() * (0.5 + min(p.mean(), 200) / 400)
            if score > best_score:
                best_score, best, best_xy = score, p, (y, x)
    if best is None:
        best_xy = (h//2, w//2)
        best = a[best_xy[0]:best_xy[0]+patch, best_xy[1]:best_xy[1]+patch].astype(np.float32)
    return best, best_xy


def texture_energy(p: np.ndarray) -> float:
    """拉普拉斯高频能量(平均|∇²|),纹理量纲。"""
    lap = (np.abs(4*p[1:-1,1:-1] - p[:-2,1:-1] - p[2:,1:-1] - p[1:-1,:-2] - p[1:-1,2:]))
    return float(lap.mean())


def split_texture(p: np.ndarray):
    """高频分解:强结构(边缘>25) vs 弱噪声(<25)。美颜该压噪声、保结构。"""
    gray = p.mean(-1)
    lap = np.abs(4*gray[1:-1,1:-1] - gray[:-2,1:-1] - gray[2:,1:-1] - gray[1:-1,:-2] - gray[1:-1,2:])
    strong = lap[lap > 25]
    weak = lap[lap <= 25]
    return float(strong.mean() if strong.size else 0), float(weak.mean() if weak.size else 0)


def ssim_simple(x: np.ndarray, y: np.ndarray) -> float:
    """SSIM(全局,7x7 均值窗近似)。"""
    x, y = x.mean(-1), y.mean(-1)
    k = 7
    xm = np.convolve(x.ravel(), np.ones(k)/k, 'valid')
    ym = np.convolve(y.ravel(), np.ones(k)/k, 'valid')
    n = min(len(xm), len(ym))
    xm, ym = xm[:n], ym[:n]
    vx, vy = xm.var(), ym.var()
    cxy = ((xm-xm.mean())*(ym-ym.mean())).mean()
    c1, c2 = (0.01*255)**2, (0.03*255)**2
    return float(((2*xm.mean()*ym.mean()+c1)*(2*cxy+c2))/((xm.mean()**2+ym.mean()**2+c1)*(vx+vy+c2)))


def main():
    before_p, after_p = sys.argv[1], sys.argv[2]
    out_png = "/tmp/beauty_ab_v2.png"
    if "--out" in sys.argv:
        out_png = sys.argv[sys.argv.index("--out")+1]
    b = np.array(Image.open(before_p).convert("RGB"))
    a = np.array(Image.open(after_p).convert("RGB"))
    if b.shape != a.shape:
        a = np.array(Image.open(after_p).convert("RGB").resize((b.shape[1], b.shape[0])))

    pb, (py, px_) = skin_patch(b)
    pa = a[py:py+96, px_:px_+96].astype(np.float32)   # 同一坐标取 after(公平对照)
    tb, ta = texture_energy(pb), texture_energy(pa)
    keep = ta / max(tb, 1e-6)
    sim = ssim_simple(pb, pa)
    sb, wb = split_texture(pb)
    sa, wa = split_texture(pa)
    struct_keep = sa / max(sb, 1e-6)   # 结构(发丝/睫毛级)保留度:该接近 1
    noise_kill = 1 - wa / max(wb, 1e-6)  # 噪声(毛孔级)压制率:该高

    # 亮度/色度(皮肤区):美白量化
    lum_b = 0.299*pb[...,0]+0.587*pb[...,1]+0.114*pb[...,2]
    lum_a = 0.299*pa[...,0]+0.587*pa[...,1]+0.114*pa[...,2]
    warm_b = pb[...,0].mean()-pb[...,2].mean()   # R-B:越低越白(去黄)
    warm_a = pa[...,0].mean()-pa[...,2].mean()

    # 非肤色区误伤:整帧四角拼块(背景假设)
    h, w, _ = b.shape
    corner = np.concatenate([
        b[0:80, 0:80].reshape(-1,3), b[0:80, w-80:w].reshape(-1,3),
        b[h-80:h, 0:80].reshape(-1,3), b[h-80:h, w-80:w].reshape(-1,3)])
    corner_a = np.concatenate([
        a[0:80, 0:80].reshape(-1,3), a[0:80, w-80:w].reshape(-1,3),
        a[h-80:h, 0:80].reshape(-1,3), a[h-80:h, w-80:w].reshape(-1,3)])
    # 均值漂移(逐像素差含重采样噪声,不代表色彩偏移;对照 identity 路径可分离)
    bg_drift = float(np.abs(corner.astype(np.float32).mean(0) - corner_a.astype(np.float32).mean(0)).mean())

    print("── 美颜 A/B 皮肤纹理量化 ──")
    print(f"皮肤区高频能量(纹理): before {tb:6.2f} → after {ta:6.2f}   总保留 {keep*100:5.1f}%")
    print(f"  结构保留(发丝/睫毛级,应≈1): {struct_keep*100:5.1f}%")
    print(f"  噪声压制(毛孔级,越高越好): {noise_kill*100:5.1f}%")
    print(f"皮肤区结构相似性 SSIM: {sim:.3f}  (1=结构不变,涂抹会崩)")
    print(f"皮肤区亮度: {lum_b.mean():5.1f} → {lum_a.mean():5.1f}  ({(lum_a.mean()-lum_b.mean()):+.1f})")
    print(f"皮肤区 R-B(越低越白): {warm_b:5.1f} → {warm_a:5.1f}  ({(warm_a-warm_b):+.1f})")
    print(f"背景四角漂移: {bg_drift:.2f}  (美颜不应碰背景,<8 优秀)")
    verdict = "✓ 通过:结构保留+压噪+背景无伤" if struct_keep >= 0.5 and noise_kill >= 0.2 and bg_drift < 8 else "✗ 需复核"
    print(verdict)
    json.dump({"texture_before": float(tb), "texture_after": float(ta), "texture_keep": float(keep),
               "struct_keep": float(struct_keep), "noise_kill": float(noise_kill),
               "ssim": float(sim), "lum_before": float(lum_b.mean()), "lum_after": float(lum_a.mean()),
               "warmth_before": float(warm_b), "warmth_after": float(warm_a), "bg_drift": float(bg_drift)},
              open("/tmp/beauty_ab_v2.json", "w"), ensure_ascii=False, indent=1)

    # 拼图
    scale = 640 / max(b.shape[1], 1)
    rb = Image.fromarray(b).resize((640, int(b.shape[0]*scale)))
    ra = Image.fromarray(a).resize((640, int(a.shape[0]*scale)))
    c = Image.new("RGB", (1310, max(rb.height, ra.height)+40), (24, 24, 28))
    c.paste(rb, (10, 40)); c.paste(ra, (660, 40))
    d = ImageDraw.Draw(c)
    d.text((10, 10), f"BEFORE raw  | skin texture {tb:.1f}", fill=(220, 220, 220))
    d.text((660, 10), f"AFTER beauty (guided+skin-mask) | keep {keep*100:.0f}%  bg-drift {bg_drift:.1f}", fill=(140, 255, 180))
    c.save(out_png)
    print(f"拼图: {out_png}")


if __name__ == "__main__":
    main()
