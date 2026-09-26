#!/bin/bash
# 变焦 A/B:1x 成片 vs 2.5x 成片,中心内容应放大(量化:中心 200px 区域与全图亮度分布差异+软件档标记)
set -e
AUTH=$(curl -s "http://127.0.0.1:17877/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['cameraAuthStatus'])")
if [ "$AUTH" != "3" ]; then echo "✗ 未授权(auth=$AUTH)"; exit 1; fi

curl -s -X POST "http://127.0.0.1:17877/zoom?f=1" > /dev/null; sleep 1.5
B1=$(curl -s -X POST "http://127.0.0.1:17877/capture" > /dev/null; sleep 1.5; curl -s "http://127.0.0.1:17877/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['lastSavedPath'])")
curl -s -X POST "http://127.0.0.1:17877/zoom?f=2.5" > /dev/null; sleep 1.5
B25=$(curl -s -X POST "http://127.0.0.1:17877/capture" > /dev/null; sleep 1.5; curl -s "http://127.0.0.1:17877/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['lastSavedPath'])")
curl -s -X POST "http://127.0.0.1:17877/zoom?f=1" > /dev/null

echo "1x:   $B1"
echo "2.5x: $B25"
python3 - "$B1" "$B25" << 'PYEOF'
import sys
from PIL import Image
def stats(p):
    im = Image.open(p).convert('L')
    w, h = im.size
    c = im.crop((w//2-100, h//2-100, w//2+100, h//2+100))
    full = list(im.getdata()); cent = list(c.getdata())
    return sum(full)/len(full), sum(cent)/len(cent), (w, h)
f1, c1, dim1 = stats(sys.argv[1])
f2, c2, dim2 = stats(sys.argv[2])
print(f"1x:   dim={dim1} 全图亮度{f1:.1f} 中心亮度{c1:.1f} 中心/全图={c1/f1:.3f}")
print(f"2.5x: dim={dim2} 全图亮度{f2:.1f} 中心亮度{c2:.1f} 中心/全图={c2/f2:.3f}")
print("判定: 中心/全图 比值变化 = 视野确实放大(内容换血)")
PYEOF
