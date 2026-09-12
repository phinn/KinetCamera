#!/bin/bash
# 轮询 API key CREATE 权限(角色升级)→ produce 建档 → fastlane release 全链路
# 用法: nohup ./auto_produce_release.sh > /tmp/kinetbend_autoproduce.log 2>&1 &
set -uo pipefail
export GEM_PATH="$HOME/.local/share/fastlane/4.0.0:/opt/homebrew/Cellar/fastlane/2.239.0/libexec"
ROOT="/Users/phinn/Documents/kinet/KinetAiDesktop/KinetTradeTools"
PROBE="$ROOT/scripts/produce_probe.rb"
POLL=120
log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "开始探测 API key CREATE 权限(每 ${POLL}s,上限 24h)…"
deadline=$(( $(date +%s) + 24*3600 ))
while [[ $(date +%s) -lt $deadline ]]; do
  out=$(ruby "$PROBE" 2>&1 | grep -v warning)
  if echo "$out" | grep -q "CREATED\|EXISTS"; then
    log "★ 建档通路打开:$(echo "$out" | tail -1)"
    break
  elif echo "$out" | grep -q "AccessForbidden"; then
    log "仍无 CREATE 权限,继续等…"
    sleep "$POLL"
  else
    log "未知输出:$(echo "$out" | tail -1),视为暂时网络问题,继续"
    sleep 30
  fi
done
if ! echo "$out" | grep -q "CREATED\|EXISTS"; then log "24h 超时,退出"; exit 2; fi

log "app record 就绪,跑 preflight…"
if python3 "$ROOT/scripts/preflight_check.py"; then
  log "preflight 绿,启动 fastlane release…"
  cd "$ROOT/KinetBend"
  if fastlane release; then
    log "★★ 全链路完成:IPA+20截图+四语元数据已上传并提交审核"
  else
    rc=$?
    log "✗ release 失败 rc=$rc(上传成功可单跑 fastlane submit_build)"
    exit $rc
  fi
else
  log "✗ preflight 未过,终止"
  exit 3
fi
