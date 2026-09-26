# KinetCamera 功能矩阵(09-26 真机链路复核版)

> 口径:✅=真机/自动化实测有证据 | 🟡=代码在但本轮未实测或待条件 | ❌=未实现
> "本轮"= 2026-09-26 20:56 复核(auth=3,内置摄在线,iPhone 未插线)

## 一、多摄像头

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| 内置摄主链(预览/拍照/录像) | ✅ | 本轮录像 3.83s h264+aac、拍照 PNG+JSON、30fps | — |
| 设备枚举+切换(switchDevice) | ✅代码 / 🟡本轮 | /switch 实测过多轮(09-26 早);本轮仅内置摄在线 | **iPhone 插线复验** |
| iPhone 连续互通相机 | ✅代码 / 🟡本轮 | Continuity 实拍 1920x1080(09-26 早,连 12fps) | 插线复验 + 三摄位(iPhone 超广角/长焦 iOS 侧) |
| 屏流伪设备 kinet.screen.0 | ✅ | 本轮 /pip 同框拍照,JSON "PIP同框×1" | — |
| PIP 双源合成 | ✅ | dual_source_pip_frame100.png + 本轮 JSON 标记 | — |
| 跨设备录像时基(PTS 守卫) | ✅ | lastVideoPTS 守卫后成片时长正常(本轮 3.83s✓) | 内置→iPhone 切换后录像复验(插线) |
| iPhone 三摄位切换(超广角/长焦) | ❌ | — | iOS 侧 AVFoundation multisource;Continuity 只透出主摄位,需 iOS app 桥或 Cable 直连枚举 |

## 二、视频录制

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| h264+aac 录像 | ✅ | 本轮 ffprobe:3.83s,h264 1280x720 30fps + aac | — |
| 录像实时美颜烧入 | ✅ | video_beauty_ab.png 99.8% 像素差异 | — |
| PIP 烧入录像 | ✅代码 / 🟡本轮 | PIP 录像实测过(09-26 早) | 本轮未复测 |
| 变焦 zoomFactor | ❌ UI 有按钮(1x),vm.setZoom 在;数码变焦仅内置摄 | 需实装 videoZoomFactor 档位表 | 上轮遗留 |
| 音频静音告警 | ✅ | 本轮 /status audioSilentWarning:true(Oray 驱动环境) | — |

## 三、AI 修正(链尾自动,无 UI 开关 —— **缺口:用户不可感知**)

| 功能 | 状态 | 证据 | 缺口/下一步 |
|---|---|---|---|
| 暗光增强(EV+Gamma) | ✅ | 本轮拍照 JSON: 亮度 47.2→87.6 improved:true | UI 入口/开关缺失 |
| 白平衡去色偏 | ✅ | 本轮: cast 13.9→-13.3,二次 WB 收敛 | 同上 |
| 水平校正 | ✅ | tilt6 蓝线金标准 0.00° | 同上 |
| 畸变校正 | ✅ | fisheye_ab_v2 弯折 11.3→7.0px | 同上 |
| AI 分数回传(blur/exposure/composition) | ✅ | 本轮 JSON 全字段在 | — |
| 修正档位 UI(用户可见可控) | ❌ | AIAnalyzer 结果只在 JSON | **加"AI修正"面板:显示 applied 列表+每项独立开关** |

## 四、拍照(痛点清单)

| 功能 | 状态 | 证据 |
|---|---|---|
| 拍照+AI 修正落盘 | ✅ 本轮(照片+伴生 JSON) | ~/Pictures/KinetCamera |
| 夜景模式 | 🟡 /night 路由在,165005 样张 improved:false(运动模糊)待复验 |
| 连拍×10 | 🟡 代码在,burst 路由实测过 |
| 回溯快门 60 帧环 | 🟡 /retro 实测过 |
| AE 锁/EV/对焦锁/峰值/网格 | ✅ UI+路由双在 |
| 美颜三档 | ✅ beauty3_report_v2(磨皮69.2%压噪/美白零背景污染) |
| 瘦脸 | ✅ faceslim_cc0(脸宽-10px,全自动化) |
| 分享/导出 | ❌ 已决策砍面板,无损 PNG 保底(已满足) |

## 本轮实锤结论(20:56-20:57)
- 录像 3.83s h264 1280x720@30 + aac,PTS 守卫生效,无 423861s 复现
- 拍照 AI 修正全链:暗光 47.2→87.6、去暖 13→-13.3、二次 WB、PIP 同框,一条 JSON 说清
- **唯二真缺口:① iPhone 未插线(多摄切换/跨设备录像复验挂起)② AI 修正无 UI 入口(用户不可见=体验上不存在)**

## 下一步优先级(抬头看总目标)
1. **插 iPhone 线** → /switch 三摄枚举 → 切换后录像复验(时基守卫真机实证)
2. **AI 修正 UI 面板**(ContentView 加档位卡片:applied 实时显示+开关)——把已验证的能力从 JSON 里捞到用户眼前
3. iPhone 三摄位(超广角/长焦)调研:iOS companion app 桥 vs Continuity 能力边界
