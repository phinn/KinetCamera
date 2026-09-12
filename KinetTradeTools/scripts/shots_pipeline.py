#!/usr/bin/env python3
"""App Store 截图管线:1320x2868 P3 嵌入 -> 无损 PNG -> ASC 命名
坑:1) 尺寸必须精确 ASC 白名单(6.9" = 1320x2868)
    2) 必须内嵌 Display P3 ICC,无 ICC 截图在 ASC 按显示原生处理会偏色
用法: python3 shots_pipeline.py <src_dir> <out_dir>
"""
from PIL import Image
import os
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else '/tmp/xbend'
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'KinetBend', 'AppStore', 'Shots')
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)

ICC = '/System/Library/ColorSync/Profiles/Display P3.icc'
LANGMAP = {'en': 'en-US', 'zh-Hans': 'zh-Hans', 'zh-Hant': 'zh-Hant', 'ja': 'ja'}
MODEMAP = {'stubup': '1-stubup', 'offset': '2-offset', 'saddle3': '3-saddle3',
           'saddle4': '4-saddle4', 'kick': '5-kick'}

ic_profile = open(ICC, 'rb').read()
count = 0
for f in sorted(os.listdir(SRC)):
    if not f.startswith('shot-'):
        continue
    stem = f[5:-4]                     # stubup-en / stubup-zh-Hans(语言可含横杠,mode 不含 → 按第一个横杠切)
    mode, lang = stem.split('-', 1)
    if lang not in LANGMAP or mode not in MODEMAP:
        print(f'skip {f}')
        continue
    img = Image.open(os.path.join(SRC, f)).convert('RGB')
    w, h = img.size
    assert (w, h) == (1320, 2868), f'{f}: 尺寸 {w}x{h} 不在 ASC 6.9 白名单'
    img.save(os.path.join(OUT, f'{MODEMAP[mode]}-{LANGMAP[lang]}.png'),
             'PNG', icc_profile=ic_profile, optimize=True)
    count += 1
print(f'{count} shots -> {OUT}')

for f in sorted(os.listdir(OUT))[:4]:
    img = Image.open(os.path.join(OUT, f))
    icc = img.info.get('icc_profile', b'')
    ok = len(icc) > 500
    print(f'  {f}: {img.size} icc={len(icc)}B {"embedded-ok" if ok else "MISSING"}')
