#!/bin/bash
# 重启后一键复验:音频一锤定音 + TCC 本名验证 + 14 用例全量回归 + 录像链复验
# 用法: bash KinetCamera/scripts/post_reboot_verify.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; FAIL=$((FAIL+1)); }

echo "=== ① 音频一锤定音(aq_probe 声学闭环) ==="
echo ">>> 请对 Mac 说话或敲桌子(5 秒采样窗口)"
xcrun swiftc -O -o /tmp/aq_verify scripts/aq_probe.swift 2>/dev/null || xcrun swiftc -O -o /tmp/aq_verify scripts/aq_probe.swift -framework CoreAudio -framework CoreFoundation 2>/dev/null
AQ_OUT=$(/tmp/aq_verify 2>&1 | tail -5)
echo "$AQ_OUT"
echo "$AQ_OUT" | grep -qE "peak=0\.0*[1-9]" && ok "音频采集出数(硬件层已恢复)" || bad "音频仍全零 → 定级 Exclave DSP/硬件,走 Apple Store 硬件诊断"

echo ""
echo "=== ② TCC 本名验证(KinetCamera 非 Terminal 代持) ==="
open -a "KinetCamera" 2>/dev/null || open KinetCamera/build/ 2>/dev/null
sleep 4
STATUS=$(curl -s --max-time 3 http://127.0.0.1:17877/status 2>/dev/null)
if [ -n "$STATUS" ]; then
  AUTH=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cameraAuthStatus'))" 2>/dev/null)
  if [ "$AUTH" = "3" ]; then
    # 关键:launchd(open) 启动也能 auth=3 = KinetCamera 本名授权落盘
    ok "launchd 启动 auth=3 → TCC 本名落盘成功(不再依赖 Terminal 上下文)"
  else
    bad "launchd 启动 auth=$AUTH → 本名未授权,查系统设置→隐私→摄像头"
  fi
  FRAME=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('mainFrameCount'))" 2>/dev/null)
  [ "${FRAME:-0}" -gt 10 ] 2>/dev/null && ok "主摄帧流 delivered=$FRAME" || bad "主摄无帧"
else
  bad "17877 服务未起"
fi

echo ""
echo "=== ③ 14 用例全量回归 ==="
xcodebuild -project KinetCamera.xcodeproj -scheme KinetCameraTests -destination 'platform=macOS' test 2>&1 | grep -E "Executed .* tests" | tail -1 | grep -q "0 failures" && ok "全量回归绿" || bad "有挂,见上方 xcodebuild 输出"

echo ""
echo "=== ④ 录像全链复验(preset 1080p / 30fps / 音轨) ==="
REC=$(curl -s -X POST --max-time 3 http://127.0.0.1:17877/record)
sleep 3
curl -s -X POST --max-time 3 http://127.0.0.1:17877/record > /dev/null
sleep 3
V=$(ls -t ~/Movies/KinetCamera/*.mov 2>/dev/null | head -1)
if [ -n "$V" ]; then
  INFO=$(ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate -of csv "$V" 2>/dev/null)
  echo "成片: $INFO"
  echo "$INFO" | grep -q "aac" && ok "音轨在(若 aq_probe 仍零,说明 app 链路写死静音轨,待查)" || bad "无音轨"
  echo "$INFO" | grep -q "30/1" && ok "30fps" || bad "帧率异常"
else
  bad "无成片"
fi

echo ""
echo "=== 结果: $PASS 过 / $FAIL 挂 ==="
[ $FAIL -eq 0 ] && echo "🎉 全绿:重启三连(音频/TCC/launchd)全部闭环"
exit 0
