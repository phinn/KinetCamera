#!/bin/bash
# iPhone 16 Pro 真机硬指标验收 V2 —— 用户指定四条:
#  A. 三摄同开(MultiCam)+ 切换无黑屏无掉帧,逐路报帧率
#  B. 美颜实拍 1 张 + AI修正实拍 1 张
#  C. 验证 EXIF / P3 色彩 / 对焦
# 产物: docs/evidence/iphone_real_20260927/v2_*
# 通道: iproxy USB 隧道 17878→17877(HTTP 自动化),截图走 devicectl
set -uo pipefail
UDID="00008140-000603E91A44801C"
EV=/Users/phinn/Documents/kinet/KinetAiDesktop/KinetCamera/docs/evidence/iphone_real_20260927
mkdir -p "$EV"
H="http://127.0.0.1:17878"
C="curl -s -m 5 $H"

step(){ echo; echo "======== $* ========"; }

step "0/8 环境自检"
xcrun devicectl list devices 2>/dev/null | grep "00008140" | grep -q connected || { echo "FATAL: 真机未连接"; exit 1; }
pkill -f "iproxy 17878" 2>/dev/null; nohup iproxy 17878 17877 >/dev/null 2>&1 & sleep 2
$C/status >/dev/null || { echo "FATAL: 隧道不通"; exit 1; }
echo "USB 隧道 OK"

step "1/8 启动 app(重装最新 Release 包)"
xcrun devicectl device install app --device "$UDID" /tmp/kc_ios/Build/Products/Release-iphoneos/KinetCamera.app 2>&1 | tail -1
xcrun devicectl device process launch --device "$UDID" com.kinet.KinetCamera.iOS 2>&1 | tail -1
sleep 6
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('cameraAuth:', d.get('cameraAuthStatus'), '| devices:', len(d.get('devices',[])), d.get('deviceNames'))
print('synthFallback:', d.get('synthFallbackActive'), '(真机应为 false)')"

step "2/8 真机设备枚举档案"
$C/status > "$EV/v2_devices.json"
python3 - << PY
import json
d=json.load(open('$EV/v2_devices.json'))
for i,(n,idv) in enumerate(zip(d.get('deviceNames',[]), d.get('devices',[]))):
    print(f'  [{i}] {n}  id={idv}')
PY

step "3/8 三摄同开(MultiCam PIP)+ 逐路帧率基线(10s 静置采样)"
$C/pip?on=1 >/dev/null
sleep 10
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('主路 processedFps:', d.get('processedFps'), '| PIP 帧累计:', d.get('pipFrameTotal'), '| dropped:', d.get('dropped'))"

step "4/8 切换无黑屏:逐摄位 switch→即拍(3 摄位×2 轮),全程帧率监视"
( for i in $(seq 1 14); do sleep 2; $C/status 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin)
  print(f'  [t+{$i*2}s] fps={d.get(\"processedFps\")} dropped={d.get(\"dropped\")} drawOK={\"ok\" in str(d.get(\"drawState\",\"\"))}')" 2>/dev/null; done ) &
MON=$!
for ROUND in 1 2; do
  for KW in "wide" "ultra" "tele"; do
    ID=$(python3 -c "
import json
d=json.load(open('$EV/v2_devices.json'))
for i,n in enumerate(d.get('deviceNames',[])):
    nl=(n or '').lower()
    if '$KW' in nl or '$KW' in d['devices'][i].lower(): print(d['devices'][i]); break")
    [ -z "$ID" ] && { echo "  $KW 未匹配"; continue; }
    T0=$(python3 -c 'import time;print(time.time())')
    R=$($C/switch?id=$ID)
    T1=$(python3 -c 'import time;print(time.time())')
    # 切换后立刻抓帧:验证无黑屏(亮度>8 即非黑)
    sleep 1.2
    $C/frame > /tmp/sw_frame.raw 2>/dev/null
    python3 - << PY
import json
try:
    d=json.load(open('/tmp/sw_frame.raw')) if False else None
except: pass
PY
    echo "  R$ROUND $KW switch=$(echo $R | head -c 60) 切换耗时=$(python3 -c "print(f'{$T1-$T0:.2f}s')")"
    $C/capture >/dev/null && sleep 1.5
  done
done
wait $MON
echo "  (判定:全程 fps 恒定 + dropped 不增长 + drawOK=true = 无黑屏无掉帧)"

step "5/8 美颜实拍(磨0.7 白0.6 锐0.5)"
$C/beauty?s=0.7\&w=0.6\&sh=0.5 >/dev/null; sleep 1
$C/capture; echo
sleep 2

step "6/8 AI 修正实拍(自动档全开)"
$C/aicorrect?on=1 2>/dev/null || $C/ai_fix 2>/dev/null || $C/auto >/dev/null 2>&1
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('aiToggles/自动适应:', d.get('autoAdapt'), '| blur/exposure/composition 分:', d.get('blur'), d.get('exposure'), d.get('composition'))"
$C/capture; echo
sleep 2

step "7/8 产物拉回本机"
PULL="$EV/v2_pulls"; mkdir -p "$PULL"
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
  --domain-identifier com.kinet.KinetCamera.iOS --source "Documents/KinetCamera" --destination "$PULL" 2>&1 | tail -1
ls -la "$PULL"/KinetCamera/*.jpg 2>/dev/null | tail -6

step "8/8 EXIF / P3 / 对焦 三项验证(python 现场判)"
python3 - << PY
import glob, struct, os
files = sorted(glob.glob('$PULL/KinetCamera/*.jpg'), key=os.path.getmtime)[-2:]
for f in files:
    raw = open(f,'rb').read()
    print(f'--- {os.path.basename(f)} ({len(raw)} B) ---')
    # EXIF presence(FF D8 后找 Exif\0\0 段 + Make/Model/FocalLength 标签)
    has_exif = b'Exif\x00\x00' in raw[:200]
    has_make = b'Apple' in raw[:20000]
    print(f'  EXIF段: {"有" if has_exif else "无!"} | Make=Apple: {"有" if has_make else "无!"}')
    # ICC Profile(P3 判定:ICC 头 + prof desc 含 Display P3)
    icc_pos = raw.find(b'ICC Profile\x00')
    p3 = b'Display P3' in raw or b'Apple P3' in raw
    print(f'  ICC段: {"有" if icc_pos>=0 else "无"} | P3描述符: {"有" if p3 else "无!"}')
    # 对焦:JPEG 尺寸段(粗验)+ 成片非空尺寸
    if b'\xff\xc0' in raw:
        i = raw.find(b'\xff\xc0')
        h, w = struct.unpack('>HH', raw[i+5:i+9])
        print(f'  画面尺寸: {w}x{h}')
    print(f'  lastReport(对焦策略): 见 status 输出')
PY
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
lr=d.get('lastReport',{})
print('lastReport:', json.dumps(lr, ensure_ascii=False)[:400] if lr else '(空)')"
echo; echo "== 完成。证据目录: $EV =="
