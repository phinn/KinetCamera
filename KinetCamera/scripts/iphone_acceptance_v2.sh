#!/bin/bash
# iPhone 16 Pro 真机硬指标验收 V2 —— 用户指定四条:
#  A. 三摄同开(MultiCam)+ 切换无黑屏无掉帧,逐路报帧率
#  B. 美颜实拍 1 张 + AI修正实拍 1 张
#  C. 验证 EXIF / P3 色彩 / 对焦
# 产物: docs/evidence/iphone_real_20260927/v2_*
# 通道: iproxy USB 隧道 17878→17877(HTTP 自动化),截图走 devicectl
set -uo pipefail
# TARGET=device(真机,iproxy 隧道)/ simulator(模拟器直连 17877,干跑验证脚本自身)
TARGET="${1:-device}"
UDID="00008140-000603E91A44801C"
SIMUDID="F3FDC20D-9960-4927-8024-FB8660EC1295"
EV=/Users/phinn/Documents/kinet/KinetAiDesktop/KinetCamera/docs/evidence/iphone_real_20260927
mkdir -p "$EV"

if [ "$TARGET" = "simulator" ]; then
    H="http://127.0.0.1:17877"
    APP="simctl:$SIMUDID"
else
    H="http://127.0.0.1:17878"
    APP="/tmp/kc_ios/Build/Products/Release-iphoneos/KinetCamera.app"
fi
CX(){ curl -s -m 5 -X POST "$H/$1"; }   # POST 路由统一入口(引号内参数不踩 & 转义雷)
C="curl -s -m 5 $H"

shot(){ # shot <name>: 截屏到证据目录(真机 devicectl / 模拟器 simctl io)
    if [ "$TARGET" = "simulator" ]; then
        xcrun simctl io "$SIMUDID" screenshot "$EV/$1.png" >/dev/null 2>&1
    else
        xcrun devicectl device capture screenshot --device "$UDID" "$EV/$1.png" >/dev/null 2>&1
    fi
}
pull_docs(){ # 成片拉回
    if [ "$TARGET" = "simulator" ]; then
        SRC="$HOME/Library/Developer/CoreSimulator/Devices/$SIMUDID/data/Containers/Data/Application"
        mkdir -p "$EV/v2_pulls/KinetCamera"
        MARKER=/tmp/.kc_pull_marker
        [ -f "$MARKER" ] && NEWER=(-newer "$MARKER") || NEWER=()
        find "$SRC" -path "*Documents/KinetCamera/*" \( -name "*.jpg" -o -name "*.mov" -o -name "*.png" \) "${NEWER[@]}" 2>/dev/null | while read f; do cp "$f" "$EV/v2_pulls/KinetCamera/"; done
        touch "$MARKER"
    else
        xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
          --domain-identifier com.kinet.KinetCamera.iOS --source "Documents/KinetCamera" --destination "$EV/v2_pulls" 2>&1 | tail -1
    fi
}

step(){ echo; echo "======== $* ========"; }

step "0/8 环境自检 [target=$TARGET]"
if [ "$TARGET" = "simulator" ]; then
    xcrun simctl list devices 2>/dev/null | grep "$SIMUDID" | grep -q Booted || { echo "FATAL: 模拟器未启动"; exit 1; }
    xcrun simctl launch "$SIMUDID" com.kinet.KinetCamera.iOS >/dev/null 2>&1
    sleep 5
else
    xcrun devicectl list devices 2>/dev/null | grep "00008140" | grep -q connected || { echo "FATAL: 真机未连接"; exit 1; }
    pkill -f "iproxy 17878" 2>/dev/null; nohup iproxy 17878 17877 >/dev/null 2>&1 & sleep 2
fi
$C/status >/dev/null || { echo "FATAL: HTTP 通道不通"; exit 1; }
echo "通道 OK [target=$TARGET]"

step "1/8 启动 app(重装最新包)"
if [ "$TARGET" = "simulator" ]; then
    xcrun simctl terminate "$SIMUDID" com.kinet.KinetCamera.iOS 2>/dev/null
    xcrun simctl install "$SIMUDID" /tmp/kc_sim/Build/Products/Debug-iphonesimulator/KinetCamera.app
    xcrun simctl privacy "$SIMUDID" grant camera com.kinet.KinetCamera.iOS
    xcrun simctl launch "$SIMUDID" com.kinet.KinetCamera.iOS >/dev/null 2>&1
else
    xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -1
    xcrun devicectl device process launch --device "$UDID" com.kinet.KinetCamera.iOS 2>&1 | tail -1
fi
sleep 6
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
print('cameraAuth:', d.get('cameraAuthStatus'), '| devices:', len(d.get('devices',[])), d.get('deviceNames'))
print('synthFallback:', d.get('synthFallbackActive'), '(真机应为 false)')"

step "2/8 设备枚举档案(硬件 devices / 合成源 synthLens)"
$C/status > "$EV/v2_devices.json"
python3 - << PY
import json
d=json.load(open('$EV/v2_devices.json'))
hw = list(zip(d.get('deviceNames',[]), d.get('devices',[])))
if hw:
    for i,(n,idv) in enumerate(hw): print(f'  [{i}] {n}  id={idv}')
else:
    print('  (硬件设备表空 —— 合成源回退态)')
    print('  synthLens =', d.get('synthLens'), '| syntheticActive =', d.get('syntheticActive'))
PY

step "3/8 三摄同开(MultiCam PIP)+ 逐路帧率基线(10s 静置采样)"
curl -s -m 5 -X POST "$H/pip?on=1" >/dev/null
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
if [ "$TARGET" = "simulator" ]; then
    # 合成源态:摄位切换走 /synthLens(uw|wide|tele)
    SWITCH_ENTRY(){ curl -s -m 5 -X POST "$H/synthLens?lens=$1"; }
else
    SWITCH_ENTRY(){ curl -s -m 5 -X POST "$H/switch?id=$1"; }
fi
for ROUND in 1 2; do
  for KW in "wide" "uw" "tele"; do
    if [ "$TARGET" = "simulator" ]; then
      LENS="$KW"
      [ "$LENS" = "ultra" ] && LENS="uw"
    else
      LENS=$(python3 -c "
import json
d=json.load(open('$EV/v2_devices.json'))
for i,n in enumerate(d.get('deviceNames',[])):
    nl=(n or '').lower()
    if '$KW' in nl or '$KW' in d['devices'][i].lower(): print(d['devices'][i]); break")
    fi
    [ -z "$LENS" ] && { echo "  $KW 未匹配"; continue; }
    T0=$(python3 -c 'import time;print(time.time())')
    R=$(SWITCH_ENTRY "$LENS")
    T1=$(python3 -c 'import time;print(time.time())')
    sleep 1.2
    echo "  R$ROUND $KW → $(echo $R | head -c 70) 切换耗时=$(python3 -c "print(f'{$T1-$T0:.2f}s')")"
    CX capture >/dev/null && sleep 1.5
  done
done
wait $MON
echo "  (判定:全程 fps 恒定 + dropped 不增长 + drawOK=true = 无黑屏无掉帧)"

step "5/8 美颜实拍(磨0.7 白0.6 锐0.5)"
curl -s -m 5 -X POST "$H/beauty?s=0.7&w=0.6&sh=0.5" >/dev/null; sleep 1
CX capture; echo
sleep 2

step "6/8 AI 修正实拍(autoAdapt 随拍照链自动生效)"
AD=$($C/status | python3 -c "import json,sys; print(json.load(sys.stdin).get('autoAdapt'))")
echo "autoAdapt=$AD (true=拍照链自动执行 AI 修正)"
CX capture; echo
sleep 2
$C/status | python3 -c "
import json,sys; d=json.load(sys.stdin)
lr=d.get('lastReport',{})
print('AI修正报告: applied=', lr.get('applied',''), '| improved=', lr.get('improved',''))"

step "7/8 产物拉回本机"
pull_docs
PULL="$EV/v2_pulls"
ls -la "$PULL"/KinetCamera/*.jpg 2>/dev/null | tail -6 || true
find "$PULL" -name "*.jpg" 2>/dev/null | tail -6

step "8/8 EXIF / P3 / 对焦 三项验证(python 现场判)"
python3 - << PY
import glob, struct, os
files = sorted(glob.glob('$PULL/KinetCamera/*.jpg'), key=os.path.getmtime)[-2:]
for f in files:
    raw = open(f,'rb').read()
    print(f'--- {os.path.basename(f)} ({len(raw)} B) ---')
    # EXIF presence(FF D8 后找 Exif\0\0 段 + Make/Model/FocalLength 标签)
    has_exif = b'Exif\x00\x00' in raw[:200]
    want = b'KinetCamera Virtual Camera' if '$TARGET' == 'simulator' else b'Apple'
    has_make = want in raw[:20000]
    print(f'  EXIF段: {"有" if has_exif else "无!"} | Make({want.decode()}): {"有" if has_make else "无!"}')
    # ICC Profile(P3 判定:ICC 头 + prof desc 含 Display P3)
    icc_pos = raw.find(b'ICC_PROFILE')
    # ICC mluc desc 是 UTF-16BE,ASCII 搜不到;两头都搜
    p3 = (b'Display P3' in raw) or ('Display P3'.encode('utf-16-be') in raw)
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
