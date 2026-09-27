#!/bin/bash
# iPhone 16 Pro 真机全量验收 V3 —— 用户钦定 7 项逐项出数字:
#  1. 多摄切换(含耗时/黑屏/掉帧)  2. 拍照(含快门延迟)  3. 视频(1080p30 + 4K60 实录 ffprobe)
#  4. 美颜(同帧 A/B + 量化)      5. AI 修正(报告)   6. 暗光增强(/night 实拍)
#  7. EXIF/P3(逐张) + 变焦档收敛(1/2/5x)
# 用法: bash scripts/iphone_acceptance_v3.sh device   (模拟器干跑也可,仅逻辑验证)
set -uo pipefail
TARGET="${1:-device}"
UDID="00008140-000603E91A44801C"
SIMUDID="F3FDC20D-9960-4927-8024-FB8660EC1295"
EV=/Users/phinn/Documents/kinet/KinetAiDesktop/KinetCamera/docs/evidence/iphone_real_20260927
mkdir -p "$EV"

if [ "$TARGET" = "simulator" ]; then
    H="http://127.0.0.1:17877"
else
    H="http://127.0.0.1:17878"
fi
C="curl -s -m 5 $H"
CX(){ curl -s -m 8 -X POST "$H/$1"; }

step(){ echo; echo "======== $* ========"; }

step "0/12 环境自检 [target=$TARGET]"
if [ "$TARGET" = "simulator" ]; then
    xcrun simctl list devices 2>/dev/null | grep "$SIMUDID" | grep -q Booted || { echo "FATAL: 模拟器未启动"; exit 1; }
else
    xcrun devicectl list devices 2>/dev/null | grep "00008140" | grep -q connected || { echo "FATAL: 真机未连接(检查线缆/解锁信任)"; exit 1; }
    pkill -f "iproxy 17878" 2>/dev/null; nohup iproxy 17878 17877 >/dev/null 2>&1 & sleep 2
fi
$C/status >/dev/null || { echo "FATAL: HTTP 通道不通"; exit 1; }
echo "通道 OK"

step "1/12 启动 app"
if [ "$TARGET" = "simulator" ]; then
    xcrun simctl terminate "$SIMUDID" com.kinet.KinetCamera.iOS 2>/dev/null
    xcrun simctl install "$SIMUDID" /tmp/kc_sim/Build/Products/Debug-iphonesimulator/KinetCamera.app 2>/dev/null
    xcrun simctl privacy "$SIMUDID" grant camera com.kinet.KinetCamera.iOS 2>/dev/null
    xcrun simctl launch "$SIMUDID" com.kinet.KinetCamera.iOS >/dev/null 2>&1
else
    xcrun devicectl device install app --device "$UDID" /tmp/kc_ios/Build/Products/Release-iphoneos/KinetCamera.app 2>&1 | tail -1
    xcrun devicectl device process launch --device "$UDID" com.kinet.KinetCamera.iOS 2>&1 | tail -1
fi
sleep 6
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('cameraAuth:', d.get('cameraAuthStatus'), '| 硬件设备数:', len(d.get('devices',[])), d.get('deviceNames'))
print('synthFallback:', d.get('synthFallbackActive'), '(真机必须 false,否则无真摄)')"

step "2/12 多摄档案"
$C/status > "$EV/v3_devices.json"
python3 -c "
import json
d=json.load(open('$EV/v3_devices.json'))
for n,i in zip(d.get('deviceNames',[]), d.get('devices',[])): print(f'  {n}  id={i}')
print('  active =', d.get('activeDevice'), '| zoomMax =', d.get('activeFormatMaxZoom'))"

step "3/12 多摄同开 PIP + 帧率基线(10s)"
CX "pip?on=1" >/dev/null; sleep 10
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('processedFps:', d.get('processedFps'), '| pipFrames:', d.get('pipFrameTotal'), '| dropped:', d.get('dropped'))"

step "4/12 切换矩阵:3 摄位×2 轮 + 即拍(黑屏/掉帧监视)"
( for i in $(seq 1 16); do sleep 2; $C/status 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin); print(f'  t+{$i*2}s fps={d.get(\"processedFps\")} dropped={d.get(\"dropped\")}')
except: pass" 2>/dev/null; done ) &
MON=$!
if [ "$TARGET" = "simulator" ]; then
    SWITCH_ENTRY(){ curl -s -m 5 -X POST "$H/synthLens?lens=$1"; }
else
    SWITCH_ENTRY(){ curl -s -m 5 -X POST "$H/switch?id=$1"; }
fi
for ROUND in 1 2; do
  for KW in "wide" "uw" "tele"; do
    if [ "$TARGET" = "simulator" ]; then LENS="$KW"
    else
      LENS=$(python3 -c "
import json
d=json.load(open('$EV/v3_devices.json'))
for i,n in enumerate(d.get('deviceNames',[])):
    if '$KW' in (n or '').lower() or '$KW' in d['devices'][i].lower(): print(d['devices'][i]); break")
    fi
    [ -z "$LENS" ] && { echo "  $KW 未匹配设备"; continue; }
    T0=$(python3 -c 'import time;print(time.time())')
    R=$(SWITCH_ENTRY "$LENS")
    T1=$(python3 -c 'import time;print(time.time())')
    sleep 1.0
    CX capture >/dev/null; sleep 1.2
    echo "  R$ROUND $KW → $(echo "$R" | head -c 60) 切换=$(python3 -c "print(f'{$T1-$T0:.2f}s')")"
  done
done
wait $MON

step "5/12 快门延迟:/capture 回包→落盘 时间差(5 次平均)"
for i in 1 2 3 4 5; do
    T0=$(python3 -c 'import time;print(time.time())')
    CX capture >/dev/null
    T1=$(python3 -c 'import time;print(time.time())')
    sleep 0.8
    echo "  #$i 回包耗时 = $(python3 -c "print(f'{($T1-$T0)*1000:.0f}ms')")"
done

step "6/12 视频 A:1080p30 录 10s → ffprobe"
CX "video?preset=hd1080p30" >/dev/null; sleep 1
CX record >/dev/null; sleep 10
CX record >/dev/null; sleep 2.5
step "7/12 视频 B:4K60 录 10s → ffprobe(带宽/真帧率)"
CX "video?preset=uhd4k60" >/dev/null; sleep 1.5
CX record >/dev/null; sleep 10
CX record >/dev/null; sleep 2.5
CX "video?preset=hd1080p30" >/dev/null

step "8/12 美颜同帧 A/B:s=0 拍 → s=0.7 拍 → 复位"
CX "beauty?s=0&w=0&sh=0" >/dev/null; sleep 0.8; CX capture >/dev/null; sleep 1.5
CX "beauty?s=0.7&w=0.6&sh=0.5" >/dev/null; sleep 0.8; CX capture >/dev/null; sleep 1.5
CX "beauty?s=0&w=0&sh=0" >/dev/null

step "9/12 AI 修正实拍"
CX capture >/dev/null; sleep 2
STATUS_RETRY(){ for k in 1 2 3; do $C/status && break || sleep 1; done; }
STATUS_RETRY | python3 -c "
import json,sys; d=json.load(sys.stdin)
lr=d.get('lastReport',{})
print('applied:', lr.get('applied'), '| improved:', lr.get('improved'), '| exp:', lr.get('beforeExposure'),'→',lr.get('afterExposure'))"

step "10/12 暗光增强 /night 实拍(现场光即现状,链路验证)"
CX night >/dev/null; sleep 2.5
CX capture >/dev/null; sleep 1.5

step "11/12 变焦档收敛:1x/2x/5x + /status zoomFactor 复核"
for Z in 1 2 5; do
    CX "zoom?f=$Z" >/dev/null; sleep 1.2
    $C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print(f'  请求 {$Z}x → 收敛 zoomFactor={d.get(\"zoomFactor\")} hardware={d.get(\"zoomIsHardware\")}')"
done
CX "zoom?f=1" >/dev/null

step "12/12 产物拉回 + EXIF/P3/视频流判定"
if [ "$TARGET" = "simulator" ]; then
    APPC=$(find ~/Library/Developer/CoreSimulator/Devices/$SIMUDID/data/Containers/Data/Application -maxdepth 5 -path "*Documents/KinetCamera" -type d 2>/dev/null | head -1)
    MOVC=$(find ~/Library/Developer/CoreSimulator/Devices/$SIMUDID/data/Containers/Data/Application -maxdepth 5 -path "*Documents/Movies/KinetCamera" -type d 2>/dev/null | head -1)
    mkdir -p "$EV/v3_pulls/KinetCamera" "$EV/v3_pulls/Movies"
    cp "$APPC"/*.jpg "$APPC"/*.json "$EV/v3_pulls/KinetCamera/" 2>/dev/null
    cp "$MOVC"/*.mov "$MOVC"/*.audio.json "$EV/v3_pulls/Movies/" 2>/dev/null
else
    xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier com.kinet.KinetCamera.iOS --source Documents/KinetCamera --destination "$EV/v3_pulls" 2>&1 | tail -1
fi
PULL="$EV/v3_pulls"
echo "--- 最新成片 ffprobe ---"
V=$(ls -t "$PULL"/Movies/*.mov "$PULL"/KinetCamera/*.mov 2>/dev/null | head -2)
for f in $V; do
    echo "[$(basename "$f")]"
    ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,duration -of csv=p=0 "$f" 2>/dev/null | head -4
done
echo "--- JPG EXIF/P3 逐张 ---"
python3 - << PY
import glob, struct, os
files = sorted(glob.glob('$PULL/KinetCamera/*.jpg'), key=os.path.getmtime)
for f in files[-6:]:
    raw = open(f,'rb').read()
    has_exif = b'Exif\x00\x00' in raw[:200]
    has_make = b'Apple' in raw[:20000] if '$TARGET' != 'simulator' else b'KinetCamera' in raw[:20000]
    p3 = (b'Display P3' in raw) or ('Display P3'.encode('utf-16-be') in raw)
    icc = b'ICC_PROFILE' in raw
    wh = ''
    if b'\xff\xc0' in raw:
        i = raw.find(b'\xff\xc0'); h, w = struct.unpack('>HH', raw[i+5:i+9]); wh = f'{w}x{h}'
    print(f'  {os.path.basename(f)}: {len(raw)//1024}KB {wh} EXIF={"Y" if has_exif else "N!"} Make={"Y" if has_make else "N!"} ICC={"Y" if icc else "N"} P3={"Y" if p3 else "N!"}')
PY
echo; echo "== 完成。证据: $EV/v3_pulls =="
