# 多摄能力实测(2026-09-26 晚)

## 硬件清单(本机 macOS 27,MacBook Air)

| 源 | 类型 | ID | 状态 |
|---|---|---|---|
| MacBook Air 相机 | 物理摄(FaceTime HD) | `6C707041-...-0001` | 1080p@30 主链 |
| kinet.screen.0 | 屏流伪设备(CGDisplayStream) | `kinet.screen.0` | 960x540@15,独立 session,永不禁用 |
| iPhone 连续互通相机 | 网络摄(iPhone 插线自动出现) | — | 等待 iPhone 在线(最后在线 09-25),上线即进 devices 列表,PIP/切换链路零改动 |

## 双摄并发实测(主摄 + 屏流)

```
POST /pip?on=1           → 全部非主摄源入 PIP
5s 并发采样:
  主摄  +153 帧 ≈ 30fps(1920x1080)
  屏流  +75 帧 ≈ 15fps(960x540)
双源并发录像 8s:h264 1280x720@30 + aac,PIP 右上烧入
  (像素方差:右上 std 73 = 屏流内容,其余区 38-70 = 房间背景)
证据:dual_source_pip_frame100.png /tmp/pip_zoom.png
成片:KinetCamera-20260926-185421.mov(1.6MB)
```

## 切换链路

```
POST /switch?id=<deviceID> → active 切换,session 重建,帧流恢复(39917 帧)
唯一物理摄时切回自身(链路通);iPhone 上线后即真双摄切换。
录像中切换被锁(preset 对齐保护,防 -16364)。
```

## 会话架构(多摄并发设计)

- 主摄:独占 session,1080p@30,全滤镜链
- PIP 源:每设备独立 session + output(上限 3 路),录像中烧入成片
- 屏流:独立于摄像头栈,任何单摄故障时 PIP 仍有内容(状态健康检查已内置)

## iPhone 复验清单(插线即跑)

```bash
curl -s -X POST http://127.0.0.1:17877/status 2>/dev/null
# devices 列表应出现 iPhone;然后:
curl -X POST "http://127.0.0.1:17877/switch?id=<iPhoneID>"   # 切 iPhone 主摄
curl -X POST "http://127.0.0.1:17877/pip?on=1"                # 三源并发(Mac摄+iPhone+屏流)
curl -X POST http://127.0.0.1:17877/record                    # 双摄 PIP 录像
```

## iPhone 连续互通闭环实测(09-26 19:24)

| 步骤 | 结果 | 证据 |
|---|---|---|
| 虚拟设备出现 | ✓ "PhinniPhone"的相机 640×480 入 AVFoundation 枚举 | cam_enum 输出 |
| app 热插拔检测 | ✓ devices 列表自动收录,无需重启 | /status devices[2] |
| /switch 切主摄 | ✓ activeDeviceID=24AA62C1... 帧流恢复 | /status mainFrameCount 93022→94809 |
| 实拍 | ✓ 1920×1080 PNG+JSON 落盘 | KinetCamera-20260926-192347-994.png |
| 录像 7s | ✓ h264 1080p30 + aac 成片 | KinetCamera-20260926-192445.mov |
| 双源并发 | ✓ iPhone主摄 + Mac内置摄 PIP 同开 | /status pipIDs |

**已知约束(如实入账)**:
1. 首拍画面全黑(iPhone 镜头物理朝下扣在桌面),非软件问题;待手机拿起重拍明亮样张
2. 连续互通音频同样 -91dB(走本机 HAL 上游,五层取证结论一致)
3. iPhone 锁屏/闲置后虚拟设备自动断开(系统行为),重新亮屏即恢复,app 热插拔自动重新收录
4. 连续互通相机源帧率 ~12fps(系统限制),录像成片仍 30fps 规格(writer 时间轴)
