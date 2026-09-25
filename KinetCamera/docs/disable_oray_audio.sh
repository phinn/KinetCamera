#!/bin/bash
# ============================================================
# Oray(向日葵/贝瑞花生)音频驱动一键禁用/恢复
# 背景:本机麦克风恒 -91dB,已排除软件链(app授权/ffmpeg直抓/
#       声学闭环扬声器放音同录均-91),根因=OrayVirtualAudioDevice
#       驱动钩死 coreaudiod/HAL。禁用需 sudo,故此脚本供人工执行。
# 用法:
#   sudo bash disable_oray_audio.sh disable   # 禁用(推荐,可逆)
#   sudo bash disable_oray_audio.sh restore   # 恢复
#   bash disable_oray_audio.sh verify         # 复验音轨(免sudo)
# ============================================================
set -u
HAL_DIR="/Library/Audio/Plug-Ins/HAL/OrayVirtualAudioDevice.driver"
QUARANTINE_DIR="/Library/Audio/Plug-Ins/HAL.disabled"          # 禁用后的存放地
LAUNCH_PLISTS=(
  /Library/LaunchDaemons/com.oray.awesun.plist
  /Library/LaunchAgents/com.oray.awesun.agent.plist
  /Library/LaunchAgents/com.oray.awesun.startup.plist
  /Library/LaunchAgents/com.oray.awesun.helper.plist
)

action="${1:-}"

do_disable() {
  echo "== [1/3] 卸载 launchd 驻留项 =="
  for p in "${LAUNCH_PLISTS[@]}"; do
    [ -f "$p" ] && launchctl bootout "$p" 2>/dev/null
    launchctl disable "system/$(basename "$p" .plist)" 2>/dev/null
    echo "  bootout: $p"
  done

  echo "== [2/3] 移走 HAL 驱动(可逆:$QUARANTINE_DIR) =="
  mkdir -p "$QUARANTINE_DIR"
  if [ -d "$HAL_DIR" ]; then
    mv "$HAL_DIR" "$QUARANTINE_DIR/" && echo "  已移走 OrayVirtualAudioDevice.driver"
  else
    echo "  驱动不在位(可能已禁用)"
  fi

  echo "== [3/3] 重启 coreaudiod 使 HAL 重载 =="
  killall coreaudiod && echo "  coreaudiod 已重启"
  echo "✅ 禁用完成。马上验证: bash $0 verify"
}

do_restore() {
  echo "== [1/2] 驱动归位 =="
  if [ -d "$QUARANTINE_DIR/OrayVirtualAudioDevice.driver" ]; then
    mv "$QUARANTINE_DIR/OrayVirtualAudioDevice.driver" "$HAL_DIR" && echo "  已恢复"
  else
    echo "  无需恢复(不在隔离区)"
  fi
  echo "== [2/2] 重载 launchd + coreaudiod =="
  for p in "${LAUNCH_PLISTS[@]}"; do
    [ -f "$p" ] && launchctl bootstrap system "$p" 2>/dev/null
  done
  killall coreaudiod
  echo "✅ 恢复完成"
}

do_verify() {
  # 复验麦克风真收声:扬声器放440Hz正弦+同时录4s,期望 mean_volume > -60dB
  echo "== 声学闭环复验(无需sudo) =="
  python3 - <<'PYEOF'
import wave, struct, math
w = wave.open('/tmp/sine440.wav','w'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
for i in range(44100*3): w.writeframes(struct.pack('<h', int(12000*math.sin(2*math.pi*440*i/44100))))
w.close()
PYEOF
  osascript -e "set volume output volume 90" -e "set volume output muted false"
  ( sleep 1; afplay /tmp/sine440.wav ) &
  ffmpeg -y -hide_banner -f avfoundation -i ":1" -t 4 -af volumedetect -f null - 2>&1 | grep -E "mean_volume|max_volume"
  wait
  echo ""
  echo "判定: mean_volume > -60dB = 音轨修复 ✅ | 仍 -91dB = HAL 还有别的钩子 ❌"
  echo "若已修复,KinetCamera 内直接录视频再验一遍:"
  echo "  curl -X POST http://127.0.0.1:17877/record   # 等5秒再发一次停止"
  echo "  ffprobe -v error -show_entries stream=codec_name,channels \$(ls -t ~/Pictures/KinetCamera/*.mov | head -1)"
}

case "$action" in
  disable) do_disable ;;
  restore) do_restore ;;
  verify)  do_verify ;;
  *) echo "用法: $0 disable|restore|verify (disable/restore 需 sudo)" ;;
esac
