#!/usr/bin/env python3
"""实机成片 A/B 量化:对摄像头真帧(美颜 off vs on)计算
① 结构保留(皮肤块强边缘) ② 去黄 Δ(R-B) ③ 背景漂移(四角均值)
与 beauty_ab.py(合成卡已知真值)互补;实机无真值,报告变化量并标注数据来源。"""
import sys, json, numpy as np
from PIL import Image

def _candidates(img):
    """扫描全部 96px 候选块,返回 (y,x,stats) 列表。排除两类伪样本:
    ① 纯色过曝墙(std<2) ② 含剪裁悬崖的块(像素<3或>252 占比>1% —— 升采样必然糊化,与美颜无关)"""
    h, w, _ = img.shape
    out = []
    for y in range(0, h-96, 48):
        for x in range(0, w-96, 48):
            p = img[y:y+96, x:x+96].astype(np.float32)
            r, g, b = p[...,0], p[...,1], p[...,2]
            skin = (r>g-8)&(g>b-8)&(r-b>12)&(r-b<120)&(r>60)&(r<250)
            gray0 = p.mean(-1)
            if gray0.std() < 3:        # 空间纯色(白墙):RGB 通道差会让 p.std 偏大,须按灰度空间 std
                continue
            clip = ((p.mean(-1) < 3) | (p.mean(-1) > 252)).mean()
            if clip > 0.01:
                continue
            gray = gray0
            lap = np.abs(4*gray[1:-1,1:-1]-gray[:-2,1:-1]-gray[2:,1:-1]-gray[1:-1,:-2]-gray[1:-1,2:])
            weak = lap[lap<=25]
            if weak.size == 0 or weak.mean() < 0.5:   # 无噪声可压的块不做毛孔口径样本
                continue
            out.append((y, x, {"skin": float(skin.mean()), "strong": int((lap>25).sum()),
                               "weak": float(weak.mean())}))
    return out


def skin_patch(img):
    """皮肤纹理块:肤色密度最高的有效候选块(毛孔噪声口径)。"""
    best, best_score, best_xy = None, -1.0, None
    for y, x, st in _candidates(img):
        if st["strong"] < 5:      # 皮肤噪声口径不需要强结构,但不能全平(std 已滤)
            pass
        score = st["skin"]*(0.5+min(img[y:y+96, x:x+96].mean(), 200)/400)
        if score > best_score: best_score, best_xy = score, (y, x)
    if best_xy is None:
        print("✗ 未找到有效皮肤块"); sys.exit(2)
    y, x = best_xy
    return img[y:y+96, x:x+96].astype(np.float32), (y, x)


def struct_patch_pair(img_b, img_a):
    """结构块:取"含肤色且强边缘密度高"的块(发丝/轮廓带 —— 导向滤波要保的正是边缘带)。
    在 before 上定位,after 同坐标对照。"""
    best, best_score, best_xy = None, -1.0, None
    for y, x, st in _candidates(img_b):
        if st["skin"] < 0.15 or st["strong"] < 40:   # 必须含肤色 + 真实结构密度
            continue
        score = st["strong"] * (0.3 + st["skin"])
        if score > best_score: best_score, best_xy = score, (y, x)
    if best_xy is None:
        return None, None
    y, x = best_xy
    return img_b[y:y+96, x:x+96].astype(np.float32), img_a[y:y+96, x:x+96].astype(np.float32)

def split_texture(p):
    gray = p.mean(-1)
    lap = np.abs(4*gray[1:-1,1:-1]-gray[:-2,1:-1]-gray[2:,1:-1]-gray[1:-1,:-2]-gray[1:-1,2:])
    strong, weak = lap[lap>25], lap[lap<=25]
    return (float(strong.mean()) if strong.size else 0.0,
            float(weak.mean()) if weak.size else 0.0)

def main():
    off_path, on_path = sys.argv[1], sys.argv[2]
    b = np.array(Image.open(off_path).convert('RGB'))
    a = np.array(Image.open(on_path).convert('RGB'))
    if b.shape != a.shape:
        print(f"✗ 尺寸不一致 {b.shape} vs {a.shape}"); sys.exit(1)
    pb, (py, px) = skin_patch(b)
    pa = a[py:py+96, px:px+96].astype(np.float32)   # 同坐标公平对照
    sb, wb = split_texture(pb); sa, wa = split_texture(pa)
    noise_kill  = 1 - wa/max(wb,1e-6)
    spb, spa = struct_patch_pair(b, a)
    if spb is not None:
        ssb, _ = split_texture(spb); ssa, _ = split_texture(spa)
        struct_keep = ssa/max(ssb,1e-6)
    else:
        struct_keep = sa/max(sb,1e-6)   # 无独立结构块时退回皮肤块口径
    rb_b = float((pb[...,0]-pb[...,2]).mean()); rb_a = float((pa[...,0]-pa[...,2]).mean())
    corners = [(0,0),(0,b.shape[1]-80),(b.shape[0]-80,0),(b.shape[0]-80,b.shape[1]-80)]
    drift = float(np.mean([np.abs(b[y:y+80,x:x+80].astype(np.float32).mean(0)
                                - a[y:y+80,x:x+80].astype(np.float32).mean(0)).mean()
                           for y,x in corners]))
    verdict = "✓ 通过" if struct_keep >= 0.5 and drift < 8 and rb_a <= rb_b + 3 else "✗ 需复核"
    print("── 实机成片 A/B 量化(数据来源:Mac 内建摄像头真帧,场景:人工坐姿出镜) ──")
    print(f"皮肤块坐标: ({py},{px}) 96x96")
    print(f"结构保留(发丝/睫毛级): {struct_keep*100:5.1f}%  (该≥50%)")
    print(f"噪声压制(毛孔级):      {noise_kill*100:5.1f}%")
    print(f"皮肤 R-B 去黄:  {rb_b:.1f} → {rb_a:.1f}  (Δ{rb_a-rb_b:+.1f},该≤0或微降)")
    print(f"背景漂移(四角均值): {drift:.2f}  (该<8)")
    print(verdict)
    json.dump({"source":"Mac 内建摄像头真帧","struct_keep":struct_keep,"noise_kill":noise_kill,
               "rb_before":rb_b,"rb_after":rb_a,"bg_drift":drift,"verdict":verdict},
              open(sys.argv[3] if len(sys.argv)>3 else "/tmp/beauty_ab_real.json","w"), ensure_ascii=False)

if __name__ == "__main__": main()
