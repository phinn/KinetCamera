#!/bin/bash
# KinetBend 上架自动链路:轮询 ASC app record → preflight → fastlane release(上传+提审)
# 用法: nohup ./watch_and_release.sh > /tmp/kinetbend_watch.log 2>&1 &
# 你只管网页建档(App Store Connect → Apps → + → KinetBend — Conduit Bender /
#   简体中文 / com.kinetai.kinetbend / KINETBEND001),脚本检测到 record 自动跑完全程。
set -uo pipefail

export GEM_HOME="$HOME/.local/share/fastlane/4.0.0"
export GEM_PATH="$HOME/.local/share/fastlane/4.0.0:/opt/homebrew/Cellar/fastlane/2.239.0/libexec"
APP_DIR="/Users/phinn/Documents/kinet/KinetAiDesktop/KinetTradeTools/KinetBend"
CHECK="$GEM_HOME/bin/ruby"   # bundled ruby
[[ -x "$CHECK" ]] || CHECK=$(command -v ruby)
PREFLIGHT="/Users/phinn/Documents/kinet/KinetAiDesktop/KinetTradeTools/scripts/preflight_check.py"
POLL=60          # 轮询间隔(秒)
MAX_HOURS=24     # 最长等 24h

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---------- 0. 前置:API key JSON ----------
if [[ ! -f /tmp/asc_key.json ]]; then
  python3 - << 'EOF'
import json, os
d = os.path.expanduser('~/.appstoreconnect/private_keys')
h = dict(key_id='WGY2HCFK9K', issuer_id='d4da77ce-6781-4aef-acdd-c7480df892d5',
         key=open(os.path.join(d, 'AuthKey_WGY2HCFK9K.p8')).read(), in_house=False, duration=1200)
open('/tmp/asc_key.json', 'w').write(json.dumps(h))
EOF
  log "asc_key.json 已生成"
fi

# ---------- 1. 轮询 app record ----------
log "开始轮询 app record(bundle: com.kinetai.kinetbend,间隔 ${POLL}s,上限 ${MAX_HOURS}h)…"
found=""
deadline=$(( $(date +%s) + MAX_HOURS * 3600 ))
while [[ -z "$found" && $(date +%s) -lt $deadline ]]; do
  if out=$("$CHECK" "$APP_DIR/../scripts/asc_check.rb" 2>&1) && echo "$out" | grep -q "app record exists: true"; then
    found=1
    log "★ app record 出现!$(echo "$out" | grep 'app:'),10s 后启动全链路"
    sleep 10
  else
    log "record 未出现,继续等…"
    sleep "$POLL"
  fi
done
if [[ -z "$found" ]]; then log "超时(${MAX_HOURS}h)未见 record,退出"; exit 2; fi

# ---------- 2. preflight 硬校验(record 建档后元数据可上传,IPA 已含 ITS 键) ----------
log "运行 preflight 硬校验…"
if ! python3 "$PREFLIGHT"; then
  log "✗ preflight 未过,人工介入(日志见上)。链路终止。"
  exit 3
fi
log "preflight 全绿"

# ---------- 3. fastlane release:元数据+截图+IPA 上传 → 选 build → 提审 ----------
log "fastlane release 开始(上传 → 等 build 处理 → 选 build → 提交审核)…"
cd "$APP_DIR"
if fastlane release; then
  log "★ 全链路完成:IPA+20 截图+四语元数据已上传,已提交审核(submitted for review)"
else
  rc=$?
  log "✗ fastlane release 失败(rc=$rc)。常见处理:"
  log "   - 首次 build 处理慢:直接重跑 fastlane release(build 就绪后 select_build 会命中)"
  log "   - 若只是提审阶段失败而上传成功:fastlane submit_build 或 ASC 后台手动提交"
  exit $rc
fi
