#!/usr/bin/env python3
"""统计 PNG 像素:均值/标准差/唯一颜色数 → 判断黑帧/实拍"""
import sys
import zlib
import struct
from collections import Counter


def read_png(path):
    with open(path, 'rb') as f:
        data = f.read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos = 8
    width = height = bit_depth = color_type = None
    idat = b''
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos+4])[0]
        ctype = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+length]
        if ctype == b'IHDR':
            width, height, bit_depth, color_type = struct.unpack('>IIBB', chunk[:10])
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break
        pos += 12 + length
    raw = zlib.decompress(idat)
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    stride = width * channels
    out = bytearray(stride * height)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p+stride])
        p += stride
        if ftype == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        out[y*stride:(y+1)*stride] = line
        prev = line
    return width, height, channels, out


def stats(path):
    w, h, ch, px = read_png(path)
    step = ch
    n = w * h
    total = 0
    total_sq = 0
    colors = Counter()
    samples = 1
    for i in range(0, n, 7):
        off = i * step
        r = px[off]
        g = px[off + 1]
        b = px[off + 2]
        lum = (r * 299 + g * 587 + b * 114) // 1000
        total += lum
        total_sq += lum * lum
        colors[(r >> 4, g >> 4, b >> 4)] += 1
        samples += 1
    mean = total / samples
    var = total_sq / samples - mean * mean
    print(f"{path}: {w}x{h} ch={ch}")
    print(f"  亮度均值={mean:.1f} 标准差={var ** 0.5:.1f} 唯一色桶(4bit)={len(colors)}")
    top = colors.most_common(3)
    print(f"  Top3色桶={top}")
    if mean < 3 and var ** 0.5 < 3:
        print("  判定: 黑帧/纯色 ❌")
    elif len(colors) < 20:
        print("  判定: 内容过于单一 ⚠️")
    else:
        print("  判定: 真实画面内容 ✅")


if __name__ == '__main__':
    for p in sys.argv[1:]:
        stats(p)
