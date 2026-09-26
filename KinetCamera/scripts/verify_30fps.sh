#!/bin/bash
# 录像 30fps 复验:POST /record → 6s → stop → ffprobe 帧率(目标 30fps,零丢帧交付)
set -e
STATUS=$(curl -s "http://127.0.0.1:17877/status")
AUTH=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin)['cameraAuthStatus'])")
if [ "$AUTH" != "3" ]; then echo "✗ app 相机未授权(auth=$AUTH),先在系统设置开闸"; exit 1; fi
BEFORE=$(echo "$STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin)['lastSavedPath'])")
curl -s -X POST "http://127.0.0.1:17877/record" > /dev/null
sleep 6
curl -s -X POST "http://127.0.0.1:17877/record" > /dev/null
sleep 2
AFTER=$(curl -s "http://127.0.0.1:17877/status" | python3 -c "import json,sys; print(json.load(sys.stdin)['lastSavedPath'])")
VID=$(echo "$AFTER" | sed 's/视频已保存 //' | tr -d '\n')
echo "video: $VID"
ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate,avg_frame_rate,nb_frames,width,height -of default=noprint_wrappers=1 "$VID"
