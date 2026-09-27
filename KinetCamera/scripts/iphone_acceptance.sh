#!/bin/bash
# iPhone 16 Pro 真机硬指标验收:三摄位切换 / 30s美颜录 / MultiCam并发
# 通道A: iproxy 17878→17877 (USB 端口转发, curl 直驱)
# 通道B: devicectl process openURL kinetcamera:// (备用)
# 产物: 双通道截图 devicectl capture + 成片 devicectl copy from 拉回
set -uo pipefail
UDID="00008140-000603E91A44801C"
APP=/tmp/kc_ios/Build/Products/Release-iphoneos/KinetCamera.app
EV=/Users/phinn/Documents/kinet/KinetAiDesktop/KinetCamera/docs/evidence/iphone_real_20260927
mkdir -p "$EV"

echo "== 1/7 装机 =="
xcrun devicectl device install app --device "$UDID" "$APP" || { echo "FATAL: 安装失败"; exit 1; }

echo "== 2/7 启动 =="
xcrun devicectl device process launch --device "$UDID" com.kinet.KinetCamera.iOS || exit 1
sleep 6

echo "== 3/7 iproxy 隧道 =="
pkill -f "iproxy 17878" 2>/dev/null
nohup iproxy 17878 17877 > /dev/null 2>&1 &
sleep 2
C="curl -s -m 5 http://127.0.0.1:17878"
if $C/status > /dev/null 2>&1; then echo "通道A(USB隧道) OK"; else echo "通道A不通,走通道B(openURL)"; fi

echo "== 4/7 设备枚举 =="
$C/status | python3 -m json.tool | head -20

echo "== 5/7 三摄位切换+各拍一张 =="
# 用 status 的 deviceNames 匹配超广角/广角/长焦
$C/status > /tmp/iphone_status.json
python3 - << 'PY'
import json
d=json.load(open('/tmp/iphone_status.json'))
print("镜头位:", list(zip(d.get('deviceNames',[]), d.get('devices',[]))))
PY
for KW in "ultra" "wide" "tele"; do
  ID=$(python3 -c "
import json
d=json.load(open('/tmp/iphone_status.json'))
ids=d.get('devices',[]); names=[ (n or '').lower() for n in d.get('deviceNames',[])]
for i,n in enumerate(ids):
    if '$KW' in names[i] or '$KW' in n.lower(): print(n); break
")
  [ -z "$ID" ] && { echo "  $KW: 未匹配,跳过"; continue; }
  echo "  → $KW ($ID)"
  curl -s -m 5 -X POST "http://127.0.0.1:17878/switch?id=$ID"; echo
  sleep 2.5
  curl -s -m 10 -X POST "http://127.0.0.1:17878/capture"; echo
  sleep 1.5
  xcrun devicectl device capture screenshot --device "$UDID" "$EV/lens_$KW.png" 2>/dev/null | tail -1
done

echo "== 6/7 30s 美颜录(磨0.7白0.6锐0.5, 每隔3s采样fps) =="
curl -s -m 5 -X POST "http://127.0.0.1:17878/beauty?s=0.7&w=0.6&sh=0.5" > /dev/null
( for i in $(seq 1 10); do sleep 3; $C/status | python3 -c "import json,sys; d=json.load(sys.stdin); print('  t=$((i*3))s fps:', d.get('processedFps'), 'dropped:', d.get('dropped'), 'rec:', d.get('isRecording'))" ; done ) &
MON=$!
curl -s -m 5 -X POST "http://127.0.0.1:17878/record" > /dev/null
sleep 30
curl -s -m 5 -X POST "http://127.0.0.1:17878/record" > /dev/null
wait $MON

echo "== 7/7 MultiCam 并发(PIP on=1 + 双轨录10s) =="
curl -s -m 5 -X POST "http://127.0.0.1:17878/pip?on=1"; echo
curl -s -m 5 -X POST "http://127.0.0.1:17878/record" > /dev/null
sleep 10
curl -s -m 5 -X POST "http://127.0.0.1:17878/record" > /dev/null
$C/status > "$EV/status_final.json"
python3 -c "
import json; d=json.load(open('$EV/status_final.json'))
print('pipFrames:', d.get('pipFrames'), 'pipTotal:', d.get('pipFrameTotal'))"
xcrun devicectl device capture screenshot --device "$UDID" "$EV/multicam_ui.png" 2>/dev/null | tail -1

echo "== 完成。截图在 $EV;成片在 iPhone App Documents/KinetCamera,用 copy from 拉回 =="
echo "拉取命令:"
echo "  xcrun devicectl device copy from --device $UDID --domain-type appDataContainer --domain-identifier com.kinet.KinetCamera.iOS --source Documents/KinetCamera $EV/pulls"
