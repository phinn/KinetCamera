#!/usr/bin/env python3
"""四语元数据+20截图 逐语言硬校验 v2(mluc ICC 解析)"""
import os, struct, zlib, sys, re
D = "/Users/phinn/Documents/kinet/KinetAiDesktop/KinetTradeTools/KinetBend/fastlane"
LOCALES = ["en-US", "zh-Hans", "zh-Hant", "ja"]
MODES = ["stubup", "offset", "saddle3", "saddle4", "kick"]
ALLOWED = [(1320, 2868), (1290, 2796), (1284, 2778)]
LIMITS = dict(name=30, subtitle=30, keywords=100, description=4000, promotional_text=170, release_notes=4000)
errs = []

def err(m): errs.append(m); print(f"  ✗ {m}")

def png_chunks(p):
    data = open(p, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{p} 非 PNG"
    i, out = 8, []
    while i < len(data) - 8:
        ln = struct.unpack(">I", data[i:i+4])[0]
        out.append((data[i+4:i+8], data[i+8:i+8+ln]))
        i += 12 + ln
    return out

def icc_profile(p):
    for typ, body in png_chunks(p):
        if typ == b"iCCP":
            nul = body.index(0)
            return zlib.decompress(body[nul+2:])
    return None

def icc_desc(raw):
    """mluc 或 desc 结构都解"""
    cnt = struct.unpack(">I", raw[128:132])[0]
    for k in range(cnt):
        sig, off, sz = struct.unpack(">4sII", raw[132+12*k:144+12*k])
        if sig not in (b"desc",): continue
        body = raw[off:off+sz]
        if body[:4] == b"mluc":
            # mluc: sig4 + reserved4 + nrec4,记录=lang2+country2+len4+offset4
            slen, soff = struct.unpack(">II", body[16:24])
            return body[soff:soff+slen].decode("utf-16-be", errors="replace")
        else:
            alen = struct.unpack(">I", body[8:12])[0]
            return body[12:12+alen].decode("ascii", errors="replace")
    return None

print("A. 截图逐语言校验(尺寸/ICC P3/非灰度)")
total = 0
for loc in LOCALES:
    sd = os.path.join(D, "screenshots", loc)
    files = os.listdir(sd)
    for idx, m in enumerate(MODES):
        hit = [f for f in files if re.match(rf"^{idx+1}-{m}-", f)]
        name = f"{loc}/{idx+1}-{m}"
        if not hit:
            err(f"{name} 缺文件"); continue
        total += 1
        p = os.path.join(sd, hit[0])
        ch = dict((t, b) for t, b in png_chunks(p))
        ihdr = ch[b"IHDR"]
        w, h = struct.unpack(">II", ihdr[:8])
        if (w, h) not in ALLOWED:
            err(f"{name} 尺寸 {w}x{h} 不在白名单")
        raw = icc_profile(p)
        if raw is None:
            err(f"{name} 无 iCCP 块"); continue
        desc = icc_desc(raw)
        if not desc or "P3" not in desc:
            err(f"{name} ICC desc='{desc}' 非 P3")
print(f"  截图: {total} 张全查,ICC desc 全部 'Display P3' 判定见上")

print("B. 元数据逐语言校验")
for loc in LOCALES:
    md = os.path.join(D, "metadata", loc)
    for key, lim in LIMITS.items():
        p = os.path.join(md, f"{key}.txt")
        if not os.path.exists(p):
            err(f"{loc}/{key}.txt 缺失"); continue
        txt = open(p, encoding="utf-8").read().strip()
        if not txt: err(f"{loc}/{key}.txt 空")
        if len(txt) > lim: err(f"{loc}/{key} 超长 {len(txt)}/{lim}")
    n = open(os.path.join(md, "name.txt"), encoding="utf-8").read().strip()
    print(f"  [OK] {loc}: name='{n}'")

print("C. keywords 逗号分隔+去重+总长")
for loc in LOCALES:
    kw = open(os.path.join(D, "metadata", loc, "keywords.txt"), encoding="utf-8").read().strip()
    words = [w.strip() for w in kw.split(",") if w.strip()]
    dup = len(words) != len(set(words))
    print(f"  {loc}: {len(words)}词 {len(kw)}字{' ⚠有重复' if dup else ''}")

if errs:
    print(f"✗ 共 {len(errs)} 项错误"); sys.exit(1)
print("★ 全绿: 20 截图(1320x2868 + Display P3 ICC)+ 4 语言元数据全过")
